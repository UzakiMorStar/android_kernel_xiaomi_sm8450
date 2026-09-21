{ pkgs ? import <nixpkgs> {} }:

let
  # Use a consistent LLVM toolchain for lld & llvm.
  llvmPkgs = pkgs.llvmPackages;

  # LineageOS/AOSP-compatible cross toolchains via nixpkgs
  aarch64-gcc = pkgs.pkgsCross.aarch64-multiplatform.buildPackages.gcc;
  arm-gcc     = pkgs.pkgsCross.armv7l-hf-multiplatform.buildPackages.gcc;

  # Symlink farm mapping nixpkgs triples → AOSP prefixes so
  # CROSS_COMPILE=aarch64-linux-androidkernel- finds real tools.
  crossTools = pkgs.runCommand "aosp-cross-tools" {
    nativeBuildInputs = [ pkgs.coreutils ];
  } ''
    mkdir -p $out/bin
    for triple in aarch64-unknown-linux-gnu armv7l-unknown-linux-gnueabihf; do
      case "$triple" in
        aarch64*) src=${aarch64-gcc}/bin ;;
        arm*)     src=${arm-gcc}/bin ;;
      esac
      for tool in "$src"/"$triple"-*; do
        base=''$(basename "$tool")
        suffix=''${base#$triple-}
        case "$triple" in
          aarch64*)
            ln -sf "$tool" "$out/bin/aarch64-linux-androidkernel-''${suffix}"
            ln -sf "$tool" "$out/bin/aarch64-linux-android-''${suffix}"
            ln -sf "$tool" "$out/bin/aarch64-linux-gnu-''${suffix}"
            ;;
          arm*)
            ln -sf "$tool" "$out/bin/arm-linux-androidkernel-''${suffix}"
            ln -sf "$tool" "$out/bin/arm-linux-androideabi-''${suffix}"
            ln -sf "$tool" "$out/bin/arm-linux-gnueabihf-''${suffix}"
            ;;
        esac
      done
    done
  '';

in pkgs.mkShell {
  name = "android-kernel-oneplus-sdm845";

  buildInputs = with pkgs; [
    # LLVM / Clang toolchain — wrapped clang for full host-tool integration
    # (crt objects, libgcc, glibc headers); warnings are filtered below.
    clang
    llvmPkgs.lld
    llvmPkgs.llvm

    # Cross binutils + GCC (AOSP-prefixed)
    crossTools

    # ccache
    ccache

    # Needed by the clang-stderr-filter wrapper scripts
    bash

    # Kernel build dependencies
    gnumake
    flex
    bison
    bc
    perl
    python3
    which
    openssl
    zlib
    xz
    lz4
    zstd
    ncurses
    elfutils
    dtc
  ];

  # Default environment
  ARCH     = "arm64";
  SUBARCH = "arm64";

  shellHook = ''
    export ARCH=arm64
    export SUBARCH=arm64
    export LLVM=1
    export LLVM_IAS=1
    export CROSS_COMPILE=aarch64-linux-androidkernel-
    export CROSS_COMPILE_ARM32=arm-linux-androidkernel-
    export CLANG_TRIPLE=aarch64-linux-gnu-

    # -------------------------------------------------------------------
    # Filtered clang wrappers that suppress cc-wrapper's cross-target
    # warning.  The warning is harmless (clang is a native cross-compiler
    # and the kernel build passes --target itself), but it fires on every
    # compilation unit so the output becomes unreadable.
    #
    # These wrappers are thin shims: they call the Nix-wrapped clang with
    # all of its system headers, crt objects, and library paths intact,
    # then strip the single warning line from stderr.
    #
    # Nix interpolates ''${pkgs.clang} at build time; the quoted heredoc
    # delimiter ('WRAPPER') prevents shell expansion of $@ and >&2 so
    # they end up verbatim in the generated script.
    # -------------------------------------------------------------------
    FILTER_DIR="$HOME/.cache/kernel-clang-filtered"
    mkdir -p "$FILTER_DIR"

    cat > "$FILTER_DIR/clang" << 'WRAPPER'
#!/usr/bin/env bash
exec ${pkgs.clang}/bin/clang "$@" 2> >(grep -v 'supplying the --target' >&2)
WRAPPER
    chmod +x "$FILTER_DIR/clang"

    cat > "$FILTER_DIR/clang++" << 'WRAPPER'
#!/usr/bin/env bash
exec ${pkgs.clang}/bin/clang++ "$@" 2> >(grep -v 'supplying the --target' >&2)
WRAPPER
    chmod +x "$FILTER_DIR/clang++"

    # The kernel build may invoke clang via ld.lld or other symlinks.
    # Re-expose those from the real toolchain so they stay on PATH.
    for tool in llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip; do
      [ -L "$FILTER_DIR/$tool" ] || ln -sf "$(command -v "$tool")" "$FILTER_DIR/$tool"
    done

    # ccache — transparent acceleration via PATH shadowing.
    export CCACHE_DIR=''${CCACHE_DIR:-$HOME/.ccache}
    mkdir -p "$CCACHE_DIR"
    export USE_CCACHE=1

    # Symlink ccache → clang / clang++ so the kernel build hits ccache
    # first.  ccache then resolves the real compiler further down PATH.
    mkdir -p "$CCACHE_DIR/bin"
    for c in clang clang++; do
      [ -L "$CCACHE_DIR/bin/$c" ] || ln -sf "$(command -v ccache)" "$CCACHE_DIR/bin/$c"
    done

    # PATH order:
    #   1. ccache symlinks     (catches clang/clang++ invocations)
    #   2. our filtered shims  (ccache resolves to these as "real" clang)
    #   3. original PATH       (everything else — ld.lld, llvm-strip, …)
    export PATH="$CCACHE_DIR/bin:$FILTER_DIR:$PATH"
  '';
}
