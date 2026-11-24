import { showHUD, showToast, Toast } from "@raycast/api";
import { runBZ } from "./bz";

export default async function HuntCommand() {
  try {
    await runBZ(["autopilot", "sweep"]);
    await showHUD("BurnZombies hunt started");
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Could not start hunt",
      message: error instanceof Error ? error.message : String(error),
    });
  }
}
