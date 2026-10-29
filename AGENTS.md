# Everysight playground

Native iOS / Swift / UIKit. The SDK is a Kotlin/Native binary, imported as MaverickAI.

- Read README.md for setup, commands, and links to the official documentation.
- SDK 0.2.0 is pinned in the Xcode project and Package.resolved. Verify official
  releases before upgrading; beta APIs can break between releases.
- Official project skills are in .agents/skills/evs-mav2-sdk-{quickstart,assistant,api-guide}.
- The project documentation MCP is configured in .codex/config.toml; restart the
  coding session after trusting the project to load it. Use public docs if absent.
- Never commit sdk.key, app.key, tokens, .local/, or .venv/.
- Run ./scripts/build-ios.sh for the simulator build. A developer key is optional
  for compilation, required for glasses/simulator authentication.
- Do not instantiate HUD objects before SDK initialization. Add screens only after
  glassesService.isReady() / onReady, not merely onConnected.
- Retain the Copy Maverick AI Compose Resources build phase and arm64-only simulator
  setting. Swift labels and protocol names must match the pinned binary/sample.
- tools/everysight contains unmodified upstream scripts with licenses and provenance.
