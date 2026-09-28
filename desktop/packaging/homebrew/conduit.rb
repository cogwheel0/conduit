cask "conduit" do
  arch arm: "arm64", intel: "x64"

  version "0.1.0"
  sha256 arm:   "0000000000000000000000000000000000000000000000000000000000000000",
         intel: "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/cogwheel0/conduit/releases/download/desktop-v#{version}/Conduit-#{version}-mac-#{arch}.dmg"
  name "Conduit"
  desc "Desktop client for Open WebUI and Hermes Agent"
  homepage "https://github.com/cogwheel0/conduit"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :monterey"

  app "Conduit.app"

  zap trash: [
    "~/Library/Application Support/Conduit",
    "~/Library/Preferences/app.cogwheel.conduit.desktop.plist",
    "~/Library/Saved Application State/app.cogwheel.conduit.desktop.savedState",
  ]
end
