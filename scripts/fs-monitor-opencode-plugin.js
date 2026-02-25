// fs-monitor-plugin.mjs
// OpenCode plugin for fs-monitor.nvim
// Logs to /tmp/fs-monitor-opencode.log for debugging.

import { appendFileSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { execSync } from "child_process";

const LOG = "/tmp/fs-monitor-opencode.log";

function log(msg) {
    try {
        const ts = new Date().toTimeString().slice(0, 8);
        appendFileSync(LOG, `[${ts}] ${msg}\n`);
    } catch {
        // ignore
    }
}

/** Collect all Neovim server sockets on macOS/Linux */
function findAllNvimSockets() {
    const sockets = [];
    const addr = process.env.NVIM_LISTEN_ADDRESS;
    if (addr) return [addr];

    // macOS: sockets in $TMPDIR/nvim.*/*/nvim.*.0
    const tmpdir = process.env.TMPDIR || "/tmp";
    try {
        const nvimDirs = readdirSync(tmpdir).filter((d) => d.startsWith("nvim."));
        for (const nvimDir of nvimDirs) {
            const nvimPath = join(tmpdir, nvimDir);
            try {
                for (const sub of readdirSync(nvimPath)) {
                    const subPath = join(nvimPath, sub);
                    try {
                        for (const f of readdirSync(subPath)) {
                            if (f.startsWith("nvim.") && f.endsWith(".0")) {
                                sockets.push(join(subPath, f));
                            }
                        }
                    } catch { }
                }
            } catch { }
        }
    } catch { }

    // Linux fallback
    try {
        for (const d of readdirSync("/tmp").filter((d) => d.startsWith("nvim."))) {
            const sock = join("/tmp", d, "0");
            try {
                statSync(sock);
                sockets.push(sock);
            } catch { }
        }
    } catch { }

    return sockets;
}

export const FSMonitorPlugin = async ({ $, directory }) => {
    log(`=== Plugin loaded ===`);
    log(`directory: ${directory}`);
    log(`TMPDIR: ${process.env.TMPDIR || "<not set>"}`);

    const sockets = findAllNvimSockets();
    log(`Found ${sockets.length} socket(s): ${sockets.join(", ")}`);

    /** Try RPC on all sockets until one works */
    async function rpc(expr) {
        if (sockets.length === 0) {
            const retry = findAllNvimSockets();
            if (retry.length === 0) {
                log(`RPC SKIP: no sockets found`);
                return;
            }
            sockets.push(...retry);
        }

        for (const sock of sockets) {
            try {
                const result =
                    await $`nvim --server ${sock} --remote-expr ${expr}`.text();
                log(`RPC OK (${sock}): ${result.trim()}`);
                return;
            } catch {
                // This socket is dead, try next
            }
        }
        log(`RPC FAIL: all ${sockets.length} sockets refused connection`);
    }

    function escapeLua(s) {
        return s.replace(/'/g, "\\'");
    }

    return {
        event: async ({ event }) => {
            log(
                `EVENT: type=${event.type} props=${JSON.stringify(event.properties || {}).slice(0, 200)}`,
            );

            if (event.type === "file.edited") {
                const filePath =
                    event.properties?.file ||
                    event.properties?.path ||
                    event.properties?.filePath ||
                    "";
                log(`file.edited: path="${filePath}"`);
                if (filePath) {
                    const escaped = escapeLua(filePath);
                    await rpc(
                        `v:lua.require('fs-monitor.providers.opencode')._on_file_changed('${escaped}')`,
                    );
                } else {
                    log(
                        `WARN: file.edited no path. keys: ${Object.keys(event.properties || {}).join(", ")}`,
                    );
                }
            } else if (event.type === "session.idle") {
                log(`session.idle`);
                await rpc(
                    "v:lua.require('fs-monitor.providers.opencode')._on_session_complete()",
                );
            }
        },

        "tool.execute.after": async (input, _output) => {
            const tool = input.tool || "";
            log(
                `tool.execute.after: tool="${tool}" args=${JSON.stringify(input.args || {}).slice(0, 200)}`,
            );

            if (
                tool === "write" ||
                tool === "edit" ||
                tool === "patch" ||
                tool === "multi_edit"
            ) {
                const filePath =
                    input.args?.file_path ||
                    input.args?.filePath ||
                    input.args?.path ||
                    "";
                if (filePath) {
                    const escaped = escapeLua(filePath);
                    await rpc(
                        `v:lua.require('fs-monitor.providers.opencode')._on_file_changed('${escaped}')`,
                    );
                }
            }
        },
    };
};
