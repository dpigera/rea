# Cursor cloud agents

This repository can boot a Cursor cloud agent with REA built from the checked-out
source and Ghidra available for native analysis. Hopper is not installed.
Hopper's automated installer is a separate optional package, and this environment
selects Ghidra instead.

The setup is [`.cursor/environment.json`](../.cursor/environment.json) plus
[`.cursor/cloud-agent-install.sh`](../.cursor/cloud-agent-install.sh). The install
script is idempotent. On a new environment build it:

- installs procps, so Linux owned-process checks can run `ps`
- installs a full OpenJDK 21 under `/usr/lib/jvm/java-21-openjdk-amd64`
- installs Node.js 24.22.1 (the version in [`.nvmrc`](../.nvmrc), inside REA's
  supported 24.x range) and npm 11.16.0 on `/usr/local/bin`. The cloud image
  may still put another supported Node first on `PATH` until a new login shell
  reads `~/.profile`. The `rea` command and the MCP entry always run
  `/usr/local/bin/node`.
- downloads Ghidra 12.1.4 PUBLIC, checks its published SHA-256, and extracts it
  to `/opt/ghidra_12.1.4_PUBLIC`
- runs `npm ci` and `npm run build:cached` in this checkout, then links `rea`
  to that source entrypoint

`GHIDRA_INSTALL_DIR`, `JAVA_HOME`, and `REA_ANALYSIS_PROVIDER=ghidra` are written
for login shells and for the MCP server. The first Ghidra-backed query imports
and auto-analyzes the program before it returns. A small binary usually finishes
inside the default startup deadline. See
[Ghidra](installation.md#ghidra) and the
[Linux owned-process prerequisite](installation.md#linux-owned-process-prerequisite).

## Start a cloud agent

1. Use a revision that contains `.cursor/environment.json` (the default branch
   after this setup is merged, or another branch that has the file).
2. In Cursor, start a Cloud Agent on this GitHub repository.
3. When Cursor creates a new environment for the repository, it records
   `.cursor/environment.json` and runs `bash .cursor/cloud-agent-install.sh`
   during the environment build. Wait until that build succeeds. Agents that
   boot before any build has succeeded use Cursor's default image and skip
   `install`, so REA and Ghidra are not there yet.
4. An environment created earlier, with no repository environment file recorded,
   keeps its saved configuration. Point that environment at this file, or save
   the same install command, then run a new build. Configuration changes apply
   to the next build, not to an agent that is already running.

The build downloads the Ghidra archive (about 543 MB) and compiles REA. Later
agents reuse the snapshot and do not repeat that install.

## MCP registration

[`.cursor/mcp.json`](../.cursor/mcp.json) registers REA the way
[manual MCP registration](installation.md#mcp-registry) describes: an absolute
Node runtime and this checkout's `scripts/rea.mjs mcp` entry, with Ghidra
selected. Cursor resolves `${workspaceFolder}` to the directory that contains
`.cursor/mcp.json`.

Project `mcp.json` is how the Cursor IDE loads this server. Cloud Agents use MCP
servers configured for the Cloud Agent (personal servers in the agent MCP
dropdown, or team servers under Dashboard → Plugins & MCPs). Add a stdio server
named `rea` with the same command, arguments, and environment as
`.cursor/mcp.json` if the cloud agent does not attach the project file itself:

- command: `/usr/local/bin/node`
- args: `/workspace/scripts/rea.mjs` and `mcp` (use the checkout path if it is
  not `/workspace`)
- env: `GHIDRA_INSTALL_DIR=/opt/ghidra_12.1.4_PUBLIC`,
  `JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64`,
  `REA_ANALYSIS_PROVIDER=ghidra`

The server has to start inside the VM, after the environment install has built
`dist/`. Restart or start a new agent after changing the registration.

## Put a target in the VM

Analysis reads a local file. REA does not fetch the target for you. Three ways
to get one into the VM:

- **Commit it** on the branch the agent starts from, or ask the agent to use a
  file that is already in the checkout. Prefer source or a small sample you
  built. Do not commit secrets or provider project databases.
- **Download it by URL.** Ask the agent to `curl` a URL you are allowed to
  fetch, for example
  `curl -fL --retry 5 -o /tmp/target.bin "https://example.com/target.bin"`.
  The environment's network policy still applies. Check the file size and
  checksum before analysis when the publisher provides one.
- **Upload it** by attaching the file to the cloud agent prompt. Cursor copies
  prompt attachments into the VM. Tell the agent the attachment name and ask it
  to analyze that path.

Pass absolute paths to REA. The same checkout also works from the terminal
inside the VM: `rea doctor --provider ghidra --json` and
`rea analyze-javascript-application /absolute/path/to/app --json`.

## Example prompt

```text
Compile this C program to /tmp/hello and use the REA MCP tools to decompile
main. Show the pseudocode and the evidence REA returns, and say what is still
unknown. Do not modify the binary.

int main(void) {
  return 0;
}
```

For a JavaScript tree already in the VM:

```text
Use REA to inspect /absolute/path/to/app as a JavaScript application. List the
modules and how they relate, and include the evidence for each claim.
```

Only analyze software you own or are allowed to examine. See
[DISCLAIMER.md](../DISCLAIMER.md).
