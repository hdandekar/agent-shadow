class AgentShadow < Formula
  desc "Run coding agents in per-project Apple Container workspaces"
  homepage "https://github.com/hdandekar/agent-shadow"
  url "https://github.com/hdandekar/agent-shadow/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "2af7ab1dd4a72b8da4775781d0d17b4ec3e0546bb72bc25af2b62de355084226"
  license "MIT"

  # Apple's container CLI is in homebrew-core (Formula/c/container.rb).
  # Declaring it here means `brew install agent-shadow` pulls it in automatically.
  depends_on "container"
  # Apple Container requires macOS 26 (Tahoe) or later for user-defined networks.
  depends_on macos: :tahoe

  def install
    bin.install "bin/agent-shadow"
    lib.install "lib/agent-shadow"
    zsh_completion.install "completions/_agent-shadow"
  end

  def caveats
    <<~EOS
      Get started:
        agent-shadow init                           # build the images, create toolchain volume and network
        agent-shadow register ~/work/my-project
        agent-shadow tools use -g node@24 npm:@anthropic-ai/claude-code
        cd ~/work/my-project && agent-shadow run claude

      Add your own image layers in ~/.config/agent-shadow/Dockerfile.ubuntu24.append,
      then rebuild with: agent-shadow init --force

      To remove agent-shadow, first remove its containers, volumes and config
      (Homebrew can't), then the program:
        agent-shadow uninstall
        brew uninstall agent-shadow
    EOS
  end

  test do
    assert_match "agent-shadow 0.1.1", shell_output("#{bin}/agent-shadow --version")
  end
end
