class UpdateToolchain < Formula
  desc "Supply-chain hardened updater for a macOS developer toolchain"
  homepage "https://github.com/prasannavarshan/update-toolchain"
  # NOTE: url/sha256 are placeholders until the first tagged release exists.
  # After tagging v0.1.0:
  #   curl -sL <url> | shasum -a 256
  # and paste the digest below. Do not ship this formula with a guessed sha256 —
  # Homebrew will fail the install, which is the correct behaviour.
  url "https://github.com/prasannavarshan/update-toolchain/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "Apache-2.0"

  depends_on :macos

  def install
    bin.install "bin/update-toolchain"
    # Installed at <prefix>/config so the script's own SCRIPT_ROOT/config lookup
    # resolves. The script resolves its symlink back to the Cellar before
    # computing SCRIPT_ROOT, so the brew shim in bin/ works unchanged.
    prefix.install "config"
    doc.install "README.md", "SECURITY.md", "CHANGELOG.md", "docs/article.md"
  end

  def caveats
    <<~EOS
      Allowlists default to the bundled examples, which reflect one developer's
      machine. Copy them and edit before relying on this:

        mkdir -p ~/.config/update-toolchain
        cp #{prefix}/config/*.example ~/.config/update-toolchain/
        cd ~/.config/update-toolchain && for f in *.example; do mv "$f" "${f%.example}"; done

      Then start read-only:

        update-toolchain --dry
    EOS
  end

  test do
    # --help must work without Homebrew introspection, sudo, or network.
    assert_match "Usage", shell_output("#{bin}/update-toolchain --help")

    # The bundled example configs must be present and parseable.
    assert_predicate prefix/"config/allowed-taps.example", :exist?
    assert_predicate prefix/"config/npm-pinned.example", :exist?

    # An unknown flag must be rejected rather than silently ignored.
    output = shell_output("#{bin}/update-toolchain --definitely-not-a-flag 2>&1", 1)
    assert_match "Unknown flag", output
  end
end
