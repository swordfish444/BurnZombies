import { Action, ActionPanel, Detail } from "@raycast/api";
import { useEffect, useState } from "react";
import { runBZ } from "./bz";

export default function AuditCommand() {
  const [markdown, setMarkdown] = useState("Running read-only BurnZombies audit…");
  const [loading, setLoading] = useState(true);

  async function refresh() {
    setLoading(true);
    try {
      const output = await runBZ(["audit"]);
      setMarkdown(`# BurnZombies Read-Only Audit\n\n\`\`\`\n${output.trim()}\n\`\`\``);
    } catch (error) {
      setMarkdown(`# BurnZombies Audit Error\n\n${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void refresh();
  }, []);

  return (
    <Detail
      isLoading={loading}
      markdown={markdown}
      actions={
        <ActionPanel>
          <Action title="Re-Run Audit" onAction={refresh} />
          <Action.OpenInBrowser title="Open BurnZombies on GitHub" url="https://github.com/swordfish444/BurnZombies" />
        </ActionPanel>
      }
    />
  );
}
