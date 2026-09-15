function main() -> void {
    //# Boot: connectors + durable runtime + HTTP server
    baml.fs.mkdir(".codemode", baml.fs.MkdirOptions { recursive: true }) catch_all (e) {
        _ => null
    };
    let app = build_app();
    //# CODEMODE_ENV_IMPORT=GITHUB_TOKEN,OTHER copies those process variables into the vault at startup
    let import_list = baml.env.get("CODEMODE_ENV_IMPORT") catch_all (e) {
        _ => null
    }
        ?? "";
    for (let name in import_list.split(",")) {
        let n = name.trim();
        if (n.length() == 0) {
            continue;
        }
        let v = baml.env.get(n) catch_all (e) {
            _ => null
        };
        if (v != null) {
            app.runtime.set_env(n, v);
        }
    }
    let port = baml.env.get("PORT") catch_all (e) {
        _ => null
    }
        ?? "8787";
    let server = baml.http.Server.bind(`127.0.0.1:${port}`);
    log.info(
        `codemode runtime "${app.runtime.name}" listening on http://${server.addr}  (connectors: ${app.runtime.connector_names().join(", ")})`,
    );
    //# SSE keepalive ticker
    spawn with baml.spawn.options(detach = true) {
        while (true) {
            baml.sys.sleep(baml.time.Duration.from_seconds(15)) catch_all (e) {
                _ => null
            };
            app.keepalive();
        }
    };
    server.serve(
        (req) -> {
            handle(app, req) catch_all (e, ctx) {
                _ => {
                    log.error(`request failed: ${ctx.to_string()}`);
                    respond(500, ErrorBody { error: ctx.to_string() })
                }
            }
        },
        websocket = (req) -> {
            ws_upgrade(app, req) catch_all (e, ctx) {
                _ => {
                    log.error(`websocket upgrade failed: ${ctx.to_string()}`);
                    baml.http.reject_websocket(req)
                }
            }
        },
    )
}
