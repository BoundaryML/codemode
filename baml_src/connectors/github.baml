// A real, read-only connector over the public GitHub API. Re-executed on
// replay: results are large idempotent reads, so the log keeps seq + args only.

class PullRequest {
    number: int,
    title: string,
    user: string,
    url: string,
    updated_at: string,
}

class Repo {
    full_name: string,
    description: string,
    stars: int,
    open_issues: int,
}

class Github {
    ctx: Ctx?,

    /// Pull requests of a public repo (max 10). state: "open" (default) | "closed".
    function list_pull_requests(
        self,
        owner: string,
        repo: string,
        state: string? = null,
    ) -> PullRequest[] throws PausedForApproval | ReplayDivergence | ConnectorError {
        let st = state ?? "open";
        call<PullRequest[]>(self.ctx, self.list_pull_requests, j({ "owner": owner, "repo": repo, "state": st }), (
        ) -> {
            let doc = gh_get(`https://api.github.com/repos/${owner}/${repo}/pulls?state=${st}&per_page=10`);
            match (doc) {
                let arr: json[] => {
                    arr.map((p) -> {
                        PullRequest {
                            number: baml.json.path_or<int>(p, ".number", 0),
                            title: baml.json.path_or<string>(p, ".title", ""),
                            user: baml.json.path_or<string>(p, ".user.login", ""),
                            url: baml.json.path_or<string>(p, ".html_url", ""),
                            updated_at: baml.json.path_or<string>(p, ".updated_at", ""),
                        }
                    })
                },
                _ => [],
            }
        })
    }
    /// Repository metadata for a public repo.
    function get_repo(
        self,
        owner: string,
        repo: string,
    ) -> Repo throws PausedForApproval | ReplayDivergence | ConnectorError {
        call<Repo>(self.ctx, self.get_repo, j({ "owner": owner, "repo": repo }), () -> {
            let p = gh_get(`https://api.github.com/repos/${owner}/${repo}`);
            Repo {
                full_name: baml.json.path_or<string>(p, ".full_name", ""),
                description: baml.json.path_or<string>(p, ".description", ""),
                stars: baml.json.path_or<int>(p, ".stargazers_count", 0),
                open_issues: baml.json.path_or<int>(p, ".open_issues_count", 0),
            }
        })
    }

    function bind(self, rt: Runtime, exec: Execution) -> Github throws never {
        Github { ctx: bind_ctx(self, rt, exec) }
    }

    implements Connector {
        function name(self) -> string throws never {
            "github"
        }
        function description(self) -> string throws never {
            "Read-only GitHub (public API, unauthenticated)."
        }
        function tools(self) -> Tool[] throws never {
            [tool(self.list_pull_requests, reexecute = true), tool(self.get_repo, reexecute = true)]
        }
    }
}

/// GET a GitHub API URL and parse the JSON body.
function gh_get(url: string) -> json throws ConnectorError {
    let res = baml.http.send(
        baml.http.Request {
            method: "GET",
            url: url,
            body: "",
            headers: { "user-agent": "codemode-baml-demo", "accept": "application/vnd.github+json" },
        },
    ) catch_all (e) {
        _ => {
            throw err("github fetch failed");
        }
    };
    if (!res.ok()) {
        throw err(`github returned ${res.status_code}`);
    }
    jparse(
        res.text() catch_all (e) {
            _ => ""
        },
    )
}
