defmodule NervesSystemRG40XXV.MixProject do
  use Mix.Project

  @github_organization "kek"
  @app :nerves_system_rg40xxv
  # The repository is named after the system, so both this and artifact_sites
  # below are derived from @app rather than spelled out. They were out of step
  # until the repository was renamed from nerves_anbernic, and a stale
  # artifact_sites entry is not loud about it: builds just look for prebuilt
  # artifacts in a repository that does not exist and fall back to building
  # from source.
  @source_url "https://github.com/#{@github_organization}/#{@app}"
  @version Path.join(__DIR__, "VERSION")
           |> File.read!()
           |> String.trim()

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      compilers: Mix.compilers() ++ [:nerves_package],
      nerves_package: nerves_package(),
      description: description(),
      package: package(),
      deps: deps(),
      aliases: aliases(),
      docs: docs()
    ]
  end

  def application do
    []
  end

  # `mix precommit` is the check to run before committing, and tooling that
  # looks for such an alias will run it instead of guessing.
  #
  # It deliberately does *not* compile. Compiling this project builds the whole
  # system: `:nerves_package` is in `compilers`, so `mix compile` starts an
  # hour-long Buildroot run in Docker whenever no cached artifact matches the
  # checksum -- which is the case after any edit to `package_files()`, README
  # included. A commit-time check that triggers that is unusable, and it fails
  # for reasons unrelated to the commit.
  #
  # These two are what CI's cheap `checks` job runs that needs neither Docker
  # nor network. `tools/check-dts.sh` is left to CI: it is worth running, but it
  # downloads a kernel tree and compiles the DTS in a container.
  defp aliases do
    [
      loadconfig: [&bootstrap/1],
      precommit: [
        "format --check-formatted",
        "cmd tools/check-consistency.sh"
      ]
    ]
  end

  defp bootstrap(args) do
    set_target()
    Application.start(:nerves_bootstrap)
    Mix.Task.run("loadconfig", args)
  end

  def cli do
    [preferred_envs: %{docs: :docs, "hex.build": :docs, "hex.publish": :docs}]
  end

  defp nerves_package do
    [
      type: :system,
      artifact_sites: [
        {:github_releases, "#{@github_organization}/#{@app}"}
      ],
      build_runner_opts: build_runner_opts(),
      platform: Nerves.System.BR,
      platform_config: [
        defconfig: "nerves_defconfig"
      ],
      env: [
        {"TARGET_ARCH", "aarch64"},
        {"TARGET_CPU", "cortex_a53"},
        {"TARGET_OS", "linux"},
        {"TARGET_ABI", "gnu"},
        {"TARGET_GCC_FLAGS",
         "-mabi=lp64 -fstack-protector-strong -mcpu=cortex-a53 -fPIE -pie -Wl,-z,now -Wl,-z,relro"}
      ],
      checksum: checksum_files()
    ]
  end

  defp deps do
    [
      {:nerves, "~> 1.11", runtime: false},
      {:nerves_system_br, "1.34.1", runtime: false},
      {:nerves_toolchain_aarch64_nerves_linux_gnu, "~> 15.3.0", runtime: false},
      {:nerves_system_linter, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.22", only: :docs, runtime: false}
    ]
  end

  defp description do
    "Nerves System - Anbernic RG40XXV handheld (Allwinner H700)"
  end

  defp docs do
    [
      # The notes and specs are extras so that links to them from the README
      # resolve. ExDoc checks such links against the generated doc set rather
      # than the filesystem, so a markdown link to a file that is not listed
      # here is reported as missing even when it exists.
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/display.md",
        "docs/bring-up.md",
        "docs/debugging.md",
        "docs/hacking.md",
        "docs/superpowers/specs/2026-08-11-nerves-rg40xxv-design.md",
        "docs/superpowers/specs/2026-08-12-display-support-plan.md",
        "docs/superpowers/specs/2026-08-12-display-panel-spec.md",
        "docs/superpowers/specs/2026-08-13-de33-register-decode.md",
        "docs/superpowers/specs/2026-08-16-verification-plan.md"
      ],
      groups_for_extras: [
        Notes: ~r"docs/[^/]+\.md",
        Design: ~r"docs/superpowers/specs/"
      ],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp package do
    [
      files: package_files(),
      licenses: ["GPL-2.0-only", "GPL-2.0-or-later"],
      links: %{"GitHub" => @source_url}
    ]
  end

  # What ships in the Hex package: everything that goes into the image, plus the
  # prose that describes it.
  defp package_files do
    checksum_files() ++ prose_files()
  end

  # What the artifact checksum is computed from, which is a different question:
  # not "what belongs in the package" but "what could change the built image".
  #
  # Anything listed here invalidates every published artifact when it changes,
  # so a comment in nerves_defconfig costs three and a half hours -- correctly,
  # because a comment there is indistinguishable to us from a real edit.
  # Prose is distinguishable, and it is excluded below.
  defp checksum_files do
    [
      "busybox",
      "fwup_include",
      "linux",
      "rootfs_overlay",
      "uboot",
      "fwup-ops.conf",
      "fwup.conf",
      "LICENSES/*",
      "mix.exs",
      "nerves_defconfig",
      # Without this a change to a kernel patch would not alter the artifact
      # checksum, so a stale cached artifact would be reused silently.
      "patches",
      "post-build.sh",
      "post-createfs.sh",
      "REUSE.toml",
      "VERSION"
    ]
  end

  # Cannot affect a single byte of the image, so editing them must not throw
  # away a 560 MB artifact and three and a half hours of CI.
  #
  # Built by addition rather than by subtracting from the package list, so that
  # renaming one of these cannot silently put it back into the checksum -- a
  # `package_files() -- ["README.md"]` would just stop matching and go quiet.
  defp prose_files do
    [
      "CHANGELOG.md",
      "README.md"
    ]
  end

  defp build_runner_opts() do
    # Download source files first to get download errors right away.
    [make_args: primary_site() ++ ["source", "all", "legal-info"]]
  end

  defp primary_site() do
    case System.get_env("BR2_PRIMARY_SITE") do
      nil -> []
      primary_site -> ["BR2_PRIMARY_SITE=#{primary_site}"]
    end
  end

  defp set_target() do
    if function_exported?(Mix, :target, 1) do
      apply(Mix, :target, [:target])
    else
      System.put_env("MIX_TARGET", "target")
    end
  end
end
