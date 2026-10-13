#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Stage the reviewed fingerprint bundle into an offline root.

The Ubuntu path installs the fingerprint layer as a .deb: build_fingerprint()
in build-liuqin-debs.sh runs build-liuqin-fingerprint-deb.py, which verifies the
public bundle, overlays the repository's current Python integration on it, and
lays the result down as package contents.  A Fedora root is assembled as a file
tree rather than through dpkg, so it needs the same three steps without the
packaging wrapper -- and it must be the same three steps, not a second
implementation of them that agrees today.

So this calls the deb builder's own functions rather than restating what they
do.  read_bundle checks the archive against the released digest, prepare_payload
re-derives the candidate metadata and rewrites the manifest, and stage_root
writes the runtime tree, the units, the modprobe blacklist and the polkit rule.
None of the three is modified here, and none of them runs systemctl, mounts
anything, or executes a target binary: the package builder's guarantee that it
never touches the host's enrollment state is inherited rather than re-established.

What the deb cannot carry is the libfprint TOD ABI library, because on Ubuntu it
is somebody else's package.  Fedora publishes no such package, so the port
builds it (tools/build-liuqin-fedora-libfprint-tod.sh) and it arrives here as a
tar to be unpacked into the same root.  Everything else -- including the kernel
module at kernel/fpc1264_spi_diag.ko, which stable_module.py loads by the path
relative to its own directory -- is inside the payload already.
"""
import argparse
import importlib.util
import json
import shutil
import tarfile
import tempfile
from pathlib import Path, PurePosixPath


def load_deb_builder(tools: Path):
    spec = importlib.util.spec_from_file_location(
        "fingerprint_deb", tools / "build-liuqin-fingerprint-deb.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def unpack_tod(tar_path: Path, root: Path) -> list[str]:
    """Unpack the TOD build's library tree into the root. Returns the paths."""
    written = []
    with tarfile.open(tar_path, "r:gz") as archive:
        for item in archive:
            name = PurePosixPath(item.name)
            # The archive carries build metadata beside the tree; only the tree
            # is content, and only files and directories are expected.  Refuse
            # anything else outright rather than inspecting it further: a link
            # in a device-layer archive is a way to write outside the root.
            if name.parts[0] != "usr":
                if item.isfile() or item.isdir():
                    continue
                raise ValueError(f"unexpected member in the TOD archive: {item.name}")
            if name.is_absolute() or ".." in name.parts:
                raise ValueError(f"unsafe member in the TOD archive: {item.name}")
            if item.issym():
                # The build emits one symlink -- libfprint-2.so.2 pointing at the
                # versioned file beside it -- and it is runtime content, not a
                # development convenience: the loader opens a library by the
                # soname recorded in its consumers, and the soname here is the
                # link's name rather than the file's.  It is recreated rather
                # than extracted, and only when it stays inside the tree: a
                # member pointing out of it is how a device-layer archive writes
                # outside its own root.
                target = PurePosixPath(item.linkname)
                if target.is_absolute() or ".." in target.parts:
                    raise ValueError(
                        f"the TOD archive links outside itself: {item.name} -> {item.linkname}")
                link = root / name
                link.parent.mkdir(parents=True, exist_ok=True)
                if link.is_symlink() or link.exists():
                    link.unlink()
                link.symlink_to(target)
                written.append("/" + name.as_posix())
                continue
            if not (item.isfile() or item.isdir()):
                raise ValueError(f"the TOD archive carries a non-file: {item.name}")
            target = root / name
            if item.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(item) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(item.mode & 0o777)
            written.append("/" + name.as_posix())
    return sorted(written)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path,
                        help="the public fingerprint-build-inputs.tar.gz")
    parser.add_argument("--tod-tar", required=True, type=Path,
                        help="libfprint-tod.tar.gz from build-liuqin-fedora-libfprint-tod.sh")
    parser.add_argument("--root", required=True, type=Path,
                        help="the Fedora root being assembled")
    parser.add_argument("--version", required=True,
                        help="the release version the candidate metadata records")
    parser.add_argument("--kernel-release-file", type=Path,
                        help="the root's own record of the kernel it carries, "
                             "e.g. usr/share/liuqin/kernel.release; when given, "
                             "the candidate's kernel_release must equal it")
    args = parser.parse_args()

    for path in (args.bundle, args.tod_tar):
        if not path.is_file():
            raise SystemExit(f"input is missing: {path}")
    if not (args.root / "usr/lib/systemd/systemd").is_file():
        raise SystemExit(f"not a Fedora root: {args.root}")

    module = load_deb_builder(Path(__file__).resolve().parents[1])

    # The one pairing this layer does not tolerate being wrong.  The module in
    # the bundle is vermagic-pinned to a single kernel release and
    # stable_module.py compares that release against the running kernel before
    # it insmods anything, so a root built from a different kernel commit
    # installs cleanly and then fails at the first login with nothing in the
    # journal to explain it.  Checking it before anything is staged means the
    # message can name both releases instead, and it leaves no half-installed
    # tree behind.
    #
    # This is a Fedora-path check rather than a shared one because it is a
    # property of how the root is assembled: the Ubuntu builder installs the
    # kernel from a package whose version the deb already depends on, while a
    # Fedora root is handed whatever kernel tree the caller built.
    if args.kernel_release_file is not None:
        if not args.kernel_release_file.is_file():
            raise SystemExit(
                f"the root does not record a kernel release at {args.kernel_release_file}")
        carried = args.kernel_release_file.read_text().strip()
        # prepare_payload refuses any bundle whose CANDIDATE.json disagrees with
        # this constant, so it is the release the module is pinned to whichever
        # bundle is passed; reading it here rather than from the archive keeps
        # the check ahead of the staging it guards.
        pinned = module.KERNEL_RELEASE
        if carried != pinned:
            raise SystemExit(
                f"the fingerprint module is built for kernel {pinned} but this root "
                f"carries {carried or '(nothing recorded)'}; build the kernel at the "
                "commit the release pins (fe81794b5e1b) or install without the layer")

    with tempfile.TemporaryDirectory(prefix="liuqin-fingerprint-root-") as temporary:
        payload = Path(temporary) / "payload"
        payload.mkdir()
        # Raises on a substituted archive, on a manifest that does not describe
        # the archive's contents, and on any file whose hash moved.
        module.read_bundle(args.bundle, payload)
        info, manifest = module.prepare_payload(payload, args.version)
        # stage_root copies the payload into place with copytree, which refuses
        # an existing destination -- the right default for the package builder,
        # whose output it must never overwrite, and the wrong one for a root
        # stage that is advertised as rerunnable.  The directory is wholly this
        # layer's: it is not in the Fedora tree, nothing else in the device
        # layer writes there, and the only way it exists before this line is
        # that this stage ran before.  Everything that would make removing it
        # unsafe -- a symlink, or a path outside the root -- is refused instead.
        runtime = args.root / module.RUNTIME_PATH
        if runtime.is_symlink():
            raise SystemExit(f"refusing to replace a symlinked runtime directory: {runtime}")
        if runtime.exists():
            if not runtime.is_dir():
                raise SystemExit(f"refusing to replace a non-directory: {runtime}")
            shutil.rmtree(runtime)
        # The same asymmetry, one file further on: the four files stage_root
        # writes into /etc are written through write_text and overwrite
        # silently, but the enable link is created with symlink_to, which
        # refuses an existing name.  Clear it only when it is the link this
        # stage made, so a different symlink there is still stage_root's to
        # refuse rather than something this removes on its behalf.
        enable = (args.root / "etc/systemd/system/multi-user.target.wants"
                  / "liuqin-fpc-stable-module.service")
        unit = Path("/usr/lib/systemd/system/liuqin-fpc-stable-module.service")
        if enable.is_symlink() and enable.readlink() == unit:
            enable.unlink()
        # Raises on a kernel release, enrollment interface or deployment mode
        # the reviewed binaries do not support, on a module whose vermagic is
        # not the release kernel's, and on any OEM TA hash that drifted.
        module.stage_root(payload, args.root, info)

    libraries = unpack_tod(args.tod_tar, args.root)

    print(json.dumps({
        "fingerprint_files": len(manifest),
        "candidate": info["id"],
        "kernel_release": info["kernel_release"],
        "kernel_module_sha256": info["kernel_module_sha256"],
        "libfprint_libraries": libraries,
    }, indent=2))


if __name__ == "__main__":
    main()
