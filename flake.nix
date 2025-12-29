{
  description = "Dev shell for AMD ROCm AI build system (Ryzen AI Max+ 395 / gfx1151)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.${system}.gmktec-rocm-dev = pkgs.mkShell {
        packages = with pkgs; [
          git
          cmake
          ninja
          gcc
          gnumake
          pkg-config
          python311
          python311Packages.pip
          python311Packages.virtualenv
          pciutils
          which
          htop
          ncdu
          tree
        ];

        shellHook = ''
          echo "[gmktec-rocm-dev] Activating dev shell"
          if [ -x ./scripts/00_detect_hardware.sh ]; then
            ./scripts/00_detect_hardware.sh || true
          fi

          if [ -x /opt/rocm/bin/hipconfig ]; then
            echo "ROCm hipconfig version: $("'/opt/rocm/bin/hipconfig' --version 2>/dev/null || echo "unknown")"
          else
            echo "ROCm hipconfig not found under /opt/rocm (host ROCm not visible?)."
          fi

          echo "Python: $(python --version)"
          echo "[gmktec-rocm-dev] Ready. Typical flow:"
          echo "  1) ./scripts/01_setup_system_dependencies.sh (once, outside Nix if needed)"
          echo "  2) ./scripts/02_install_python_env.sh"
          echo "  3) ./scripts/20_build_pytorch_rocm.sh"
          echo "  4) ./scripts/30_build_vllm_rocm_or_cpu.sh"
          echo "  5) ./scripts/41_build_llama_cpp_rocm.sh"
        '';
      };
    };
}
