#!/usr/bin/env python3
"""Stage IA16 newlib headers for an explicit, host-independent Clang probe.

The IA16 install contains target overlays (for example, sys/config.h) at the
same paths as generic newlib headers.  The overlays use include_next, so a
consumer must put the target tree before a separately preserved generic tree.
This script constructs those two tiers from a completed build/install and
runs the checked-in syntax-only oracle through the selected Clang.

The source, build, and install trees are read-only inputs.  The output must be
a new directory; refusing to reuse it keeps a result reproducible and avoids
silently modifying an install prefix.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
from typing import Iterable, Optional


TARGET_DEFAULT = "ia16-pc-msdos"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_manifest(root: Path) -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise RuntimeError(f"symlink is not allowed in staged headers: {path}")
        if path.is_file():
            entries.append(
                {
                    "path": path.relative_to(root).as_posix(),
                    "size": path.stat().st_size,
                    "sha256": sha256_file(path),
                }
            )
        elif not path.is_dir():
            raise RuntimeError(f"unsupported directory entry in headers: {path}")
    return entries


def copy_tree(source: Path, destination: Path) -> list[dict[str, object]]:
    """Copy a regular-file header tree without following links."""

    if not source.is_dir():
        raise RuntimeError(f"header tree does not exist: {source}")
    destination.mkdir(parents=True, exist_ok=False)
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        target = destination / relative
        if path.is_symlink():
            raise RuntimeError(f"symlink is not allowed in staged headers: {path}")
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        elif path.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target, follow_symlinks=False)
        else:
            raise RuntimeError(f"unsupported directory entry in headers: {path}")
    return file_manifest(destination)


def git_metadata(source_root: Path) -> dict[str, object]:
    metadata: dict[str, object] = {}
    for name, command in (
        ("commit", ["git", "-C", str(source_root), "rev-parse", "HEAD"]),
        ("status", ["git", "-C", str(source_root), "status", "--porcelain"]),
    ):
        try:
            result = subprocess.run(
                command,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except (OSError, subprocess.CalledProcessError):
            metadata[name] = None if name == "commit" else "unavailable"
            continue
        if name == "commit":
            metadata[name] = result.stdout.strip()
        else:
            metadata["dirty"] = bool(result.stdout.strip())
    return metadata


def path_is_under(path: Path, roots: Iterable[Path]) -> bool:
    for root in roots:
        try:
            path.relative_to(root)
        except ValueError:
            continue
        return True
    return False


HEADER_TRACE = re.compile(r"^\.+\s+(.+)$")


def traced_header_paths(stderr: str) -> list[Path]:
    """Extract existing absolute files from Clang's -H lines."""

    paths: list[Path] = []
    for line in stderr.splitlines():
        match = HEADER_TRACE.match(line)
        if not match:
            continue
        candidate = Path(match.group(1).strip())
        if not candidate.is_absolute() or not candidate.is_file():
            continue
        paths.append(candidate.resolve())
    return paths


def shell_assignment(name: str, value: str) -> str:
    return f"export {name}={shlex.quote(value)}"


def write_profile(
    path: Path,
    *,
    clang: Path,
    target: str,
    resource_include: Path,
    overlay: Path,
    generic: Path,
    oracle: Path,
    install_lib: Path,
) -> None:
    flags = " ".join(
        shlex.quote(value)
        for value in (
            f"--target={target}",
            "-march=8086",
            "-mmemory-model=small",
            "-std=gnu23",
            "-ffreestanding",
            "-fno-builtin",
            "-nostdinc",
            "-isystem",
            str(resource_include),
            "-isystem",
            str(overlay),
            "-isystem",
            str(generic),
        )
    )
    content = "\n".join(
        [
            "# Generated by stage-clang-sysroot.py; source this file, do not edit.",
            shell_assignment("IA16_CLANG", str(clang)),
            shell_assignment("IA16_TARGET", target),
            shell_assignment("IA16_RESOURCE_INCLUDE", str(resource_include)),
            shell_assignment("IA16_INCLUDE_OVERLAY", str(overlay)),
            shell_assignment("IA16_INCLUDE_GENERIC", str(generic)),
            shell_assignment("IA16_NEWLIB_LIB", str(install_lib)),
            shell_assignment("IA16_HEADER_ORACLE", str(oracle)),
            shell_assignment("IA16_HEADER_CFLAGS", flags),
            "",
            "# Use the function below so the argument boundaries are preserved in",
            "# POSIX shells as well as shells (such as zsh) that disable word splitting.",
            "ia16_clang_header() {",
            "  \"$IA16_CLANG\" " + "\\",
            *[
                "    " + shlex.quote(value) + " " + "\\"
                for value in (
                    f"--target={target}",
                    "-march=8086",
                    "-mmemory-model=small",
                    "-std=gnu23",
                    "-ffreestanding",
                    "-fno-builtin",
                    "-nostdinc",
                    "-isystem",
                    str(resource_include),
                    "-isystem",
                    str(overlay),
                    "-isystem",
                    str(generic),
                )
            ],
            "    \"$@\"",
            "}",
            "",
        ]
    )
    path.write_text(content, encoding="utf-8")
    path.chmod(0o644)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="stage IA16 target and generic newlib headers for Clang"
    )
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--tool-root", required=True, type=Path)
    parser.add_argument("--build-root", required=True, type=Path)
    parser.add_argument("--install-prefix", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--target", default=TARGET_DEFAULT)
    return parser.parse_args()


def fail_result(output: Optional[Path], result: dict[str, object], message: str) -> int:
    result["status"] = "fail"
    result["error"] = message
    if output is not None and output.is_dir():
        (output / "results.json").write_text(
            json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    print(json.dumps(result, indent=2, sort_keys=True), file=sys.stderr)
    return 1


def main() -> int:
    args = parse_args()
    source_root = args.source_root.resolve()
    tool_root = args.tool_root.resolve()
    build_root = args.build_root.resolve()
    install_prefix = args.install_prefix.resolve()
    output = args.output.resolve()
    target = args.target
    result: dict[str, object] = {
        "status": "not_started",
        "target": target,
        "source_root": str(source_root),
        "tool_root": str(tool_root),
        "build_root": str(build_root),
        "install_prefix": str(install_prefix),
        "output": str(output),
    }
    output_created = False

    try:
        for label, path in (
            ("source root", source_root),
            ("tool root", tool_root),
            ("completed build root", build_root),
            ("install prefix", install_prefix),
        ):
            if not path.is_dir():
                raise RuntimeError(f"{label} does not exist: {path}")
        if output.exists():
            raise RuntimeError(f"output already exists; choose a new directory: {output}")

        source_generic = source_root / "newlib" / "libc" / "include"
        source_target = source_root / "newlib" / "libc" / "machine" / "ia16"
        oracle_source = source_root / "libgloss" / "ia16" / "tests" / "clang-sysroot" / "headers.c"
        for label, path in (
            ("generic source headers", source_generic),
            ("IA16 source headers", source_target),
        ):
            if not path.is_dir():
                raise RuntimeError(f"{label} do not exist: {path}")
        if not oracle_source.is_file():
            raise RuntimeError(f"checked-in header oracle does not exist: {oracle_source}")

        clang = tool_root / "bin" / "clang"
        if not clang.is_file() or not os.access(clang, os.X_OK):
            raise RuntimeError(f"executable Clang not found under tool root: {clang}")
        resource_result = subprocess.run(
            [str(clang), f"--target={target}", "-print-resource-dir"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        resource_dir = Path(resource_result.stdout.strip()).resolve()
        resource_include = resource_dir / "include"
        if not resource_include.is_dir():
            raise RuntimeError(f"Clang resource headers do not exist: {resource_include}")

        overlay_source = build_root / target / "newlib" / "targ-include"
        generic_source = install_prefix / target / "include" / "newlib"
        install_lib = install_prefix / target / "lib"
        if not install_lib.is_dir():
            raise RuntimeError(f"installed target library directory does not exist: {install_lib}")
        if not overlay_source.is_dir():
            raise RuntimeError(f"target overlay from completed build does not exist: {overlay_source}")
        if not generic_source.is_dir():
            raise RuntimeError(
                "preserved generic install tree is missing; expected "
                f"{generic_source} (install the generic headers under include/newlib)"
            )

        output.mkdir(parents=True)
        output_created = True
        overlay = output / "include" / "overlay"
        generic = output / "include" / "generic"
        overlay.parent.mkdir()
        overlay_manifest = copy_tree(overlay_source, overlay)
        generic_manifest = copy_tree(generic_source, generic)
        oracle = output / "header-oracle.c"
        shutil.copy2(oracle_source, oracle)
        profile = output / "profile.sh"
        write_profile(
            profile,
            clang=clang,
            target=target,
            resource_include=resource_include,
            overlay=overlay,
            generic=generic,
            oracle=oracle,
            install_lib=install_lib,
        )

        command = [
            str(clang),
            f"--target={target}",
            "-march=8086",
            "-mmemory-model=small",
            "-std=gnu23",
            "-ffreestanding",
            "-fno-builtin",
            "-nostdinc",
            "-isystem",
            str(resource_include),
            "-isystem",
            str(overlay),
            "-isystem",
            str(generic),
            "-H",
            "-fsyntax-only",
            str(oracle),
        ]
        try:
            compile_result = subprocess.run(
                command,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=120,
            )
        except subprocess.TimeoutExpired as exc:
            stdout = exc.stdout or ""
            stderr = exc.stderr or ""
            return fail_result(
                output,
                {
                    **result,
                    "command": command,
                    "compiler_returncode": None,
                    "stdout": stdout,
                    "stderr": stderr,
                },
                "header oracle timed out",
            )

        stdout = compile_result.stdout
        stderr = compile_result.stderr
        (output / "header-oracle.log").write_text(
            "$ " + shlex.join(command) + "\n\n" + stdout + stderr,
            encoding="utf-8",
        )
        traced = traced_header_paths(stderr)
        allowed_roots = [resource_include.resolve(), overlay.resolve(), generic.resolve()]
        outside = sorted(
            {str(path) for path in traced if not path_is_under(path, allowed_roots)}
        )

        def has_header(root: Path, relative: str) -> bool:
            expected = (root / relative).resolve()
            return expected in traced

        sys_config_pair = has_header(overlay, "sys/config.h") and has_header(
            generic, "sys/config.h"
        )
        ieeefp_pair = has_header(overlay, "machine/ieeefp.h") and has_header(
            generic, "machine/ieeefp.h"
        )
        result = {
            **result,
            "status": "pass"
            if compile_result.returncode == 0 and not outside and sys_config_pair and ieeefp_pair
            else "fail",
            "command": command,
            "compiler": str(clang),
            "compiler_sha256": sha256_file(clang),
            "resource_dir": str(resource_dir),
            "resource_include": str(resource_include),
            "resource_stddef_sha256": sha256_file(resource_include / "stddef.h")
            if (resource_include / "stddef.h").is_file()
            else None,
            "compiler_returncode": compile_result.returncode,
            "traced_headers": [str(path) for path in traced],
            "include_paths_outside_allowed_roots": outside,
            "include_next_sys_config": sys_config_pair,
            "include_next_machine_ieeefp": ieeefp_pair,
            "overlay_manifest": overlay_manifest,
            "generic_manifest": generic_manifest,
            "oracle_sha256": sha256_file(oracle),
            "source": git_metadata(source_root),
        }
        if result["status"] != "pass":
            result["error"] = "header oracle or include-path checks failed"
        (output / "results.json").write_text(
            json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["status"] == "pass" else 1
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        return fail_result(output if output_created else None, result, str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
