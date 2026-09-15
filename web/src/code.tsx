import { useEffect, useState } from "react";
import { createHighlighterCore, type HighlighterCore } from "shiki/core";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";
import json from "@shikijs/langs/json";
import githubLight from "@shikijs/themes/github-light";
// Vendored from boundaryml/baml typescript2/pkg-grammar/baml.tmLanguage.json (the
// canonical TextMate grammar). The npm @boundaryml/baml-grammar lags behind it.
import baml from "./grammar/baml.tmLanguage.json";

// One highlighter for the page, created on first use. Only the light theme and
// the two languages we show are loaded, so no WASM and no full Shiki bundle.
let ready: Promise<HighlighterCore> | null = null;
function highlighter() {
  ready ??= createHighlighterCore({
    themes: [githubLight],
    langs: [baml as never, json],
    engine: createJavaScriptRegexEngine({ forgiving: true }),
  });
  return ready;
}

/** A read-only code block. Renders plain text immediately, then colors it. */
export function Code({ src, lang = "baml" }: { src: string; lang?: "baml" | "json" }) {
  const [html, setHtml] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    highlighter()
      .then((h) => { if (live) setHtml(h.codeToHtml(src, { lang, theme: "github-light" })); })
      .catch(() => { if (live) setHtml(null); });
    return () => { live = false; };
  }, [src, lang]);
  return html ? <div className="code" dangerouslySetInnerHTML={{ __html: html }} /> : <pre>{src}</pre>;
}
