import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export function findBurnZombiesCLI(): string | null {
  const candidates = [
    "/Applications/BurnZombies.app/Contents/MacOS/burnzombies",
    `${homedir()}/Applications/BurnZombies.app/Contents/MacOS/burnzombies`,
    "/opt/homebrew/bin/burnzombies",
    "/usr/local/bin/burnzombies",
  ];
  return candidates.find((p) => existsSync(p)) ?? null;
}

export async function runBZ(args: string[]): Promise<string> {
  const cli = findBurnZombiesCLI();
  if (!cli) {
    throw new Error(
      "BurnZombies is not installed. Run `brew install --cask swordfish444/tap/burnzombies` or download from https://github.com/swordfish444/BurnZombies/releases."
    );
  }
  const { stdout } = await execFileAsync(cli, args, { timeout: 60_000, maxBuffer: 4 * 1024 * 1024 });
  return stdout;
}
