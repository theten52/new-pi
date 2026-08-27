#!/bin/sh
# XcodeBuildMCP startup wrapper for the NewPi workspace.
#
# The MCP server reads <workspace>/.xcodebuildmcp/config.yaml based purely on
# its process cwd, but Hermes spawns stdio MCP servers from the agent's home
# directory — so the project config would be missed and the macOS workflow
# tools wouldn't be exposed. This wrapper cds into the repo first, then runs
# the real server, so it always picks up the version-controlled config.
#
# Adjust the npx path if your Hermes node binary lives elsewhere.

cd "$(dirname "$0")/.." || exit 1
exec "$HOME/.hermes/node/bin/npx" -y xcodebuildmcp@latest mcp
