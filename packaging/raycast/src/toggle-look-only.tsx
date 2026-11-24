import { showHUD, showToast, Toast } from "@raycast/api";
import { runBZ } from "./bz";

export default async function ToggleLookOnlyCommand() {
  try {
    const raw = await runBZ(["autopilot"]);
    const data = JSON.parse(raw);
    const next = !(data.sweep?.lookOnly === true);
    await runBZ(["autopilot", next ? "look-only" : "start-burning"]);
    await showHUD(next ? "BurnZombies: Look-only enabled" : "BurnZombies: Burning resumed");
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Could not toggle Look-Only",
      message: error instanceof Error ? error.message : String(error),
    });
  }
}
