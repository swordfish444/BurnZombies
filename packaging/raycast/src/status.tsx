import { Action, ActionPanel, Detail } from "@raycast/api";
import { useEffect, useState } from "react";
import { runBZ } from "./bz";

export default function StatusCommand() {
  const [markdown, setMarkdown] = useState("Loading BurnZombies status…");
  const [loading, setLoading] = useState(true);

  async function refresh() {
    setLoading(true);
    try {
      const raw = await runBZ(["autopilot"]);
      const data = JSON.parse(raw);
      const lookOnly = data.sweep?.lookOnly === true ? "Look-only (nothing burns)" : data.sweep?.enabled ? "Autopilot On" : "Autopilot Off";
      const counts = data.counts ?? {};
      const lines = [
        `# BurnZombies Status`,
        ``,
        `- **Mode:** ${lookOnly}`,
        `- **Open questions:** ${(data.questions ?? []).length}`,
        `- **Ready to burn:** ${counts.burn ?? 0}`,
        `- **Unsure:** ${counts.unsure ?? 0}`,
        `- **Protected:** ${counts.protected ?? 0}`,
        `- **Backup retention:** ${data.sweep?.backupRetentionDays === 0 ? "Off (use at your own risk)" : `${data.sweep?.backupRetentionDays ?? 7} days`}`,
      ];
      setMarkdown(lines.join("\n"));
    } catch (error) {
      setMarkdown(`# BurnZombies Status Error\n\n${error instanceof Error ? error.message : String(error)}`);
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
          <Action title="Refresh" onAction={refresh} />
        </ActionPanel>
      }
    />
  );
}
