# What we borrowed from 20 developer-tool READMEs

Checked 2026-10-25 against the actual default-branch README contents through GitHub's API. Discovery used `topic:cli stars:>20000`, sorted by stars descending, with 40 results. The table follows the first 20 user-facing tools selected from that search, excluding application-development libraries/frameworks and standalone skill packs. This is a scoped, curated top-star sample, not a claim to rank every tool on GitHub. Stars are discovery signals, not validation of a tool or its claims. No installation commands from these READMEs were executed.

| Tool | README pattern worth learning from | Applied to BurnZombies |
|---|---|---|
| [REA](https://github.com/morluto/rea#readme) | Outcome-led headline, quick start, concrete showcases | One promise, one launch path, one useful preview |
| [n8n](https://github.com/n8n-io/n8n#readme) | Product screenshot directly after positioning; short capability list | Show the actual interface before the architecture |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp#readme) | Strong wordmark, platform/version badges, navigable detailed reference | A compact badge row; move deep operational detail into a guide |
| [Oh My Zsh](https://github.com/ohmyzsh/ohmyzsh#readme) | Distinctive voice, humor, collapsed navigation | “Tame the horde” and “You build. We burn.” without an essay |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli#readme) | CI/version/license signals and a short installation path | Link real CI and requirements; do not imply a packaged release exists |
| [Agent Reach](https://github.com/Panniantong/Agent-Reach#readme) | Clear agent audience and prominent quick-start navigation | Explain the long-running agent operator's problem immediately |
| [Sherlock](https://github.com/sherlock-project/sherlock#readme) | Logo, simple navigation, visible demo before usage | Let people recognize the product in seconds |
| [OpenHands](https://github.com/OpenHands/OpenHands#readme) | Audience-specific positioning, screenshot, separated setup modes | Separate everyday app use from disposable-helper registration |
| [RTK](https://github.com/rtk-ai/rtk#readme) | Agent-agnostic positioning plus measurement and “how it works” paths | Show impact while keeping calculation details available |
| [fzf](https://github.com/junegunn/fzf#readme) | Distinct identity, interactive preview, examples and integrations | A short UI tour and an explicit ownership-wrapper example |
| [lazygit](https://github.com/jesseduffield/lazygit#readme) | Embedded demo video and feature-sized demonstrations | Short preview focused on one understandable journey |
| [career-ops](https://github.com/career-ops-hq/career-ops#readme) | Human problem, concrete outcome, explicit action boundary | Less process babysitting; active work remains protected |
| [ripgrep](https://github.com/BurntSushi/ripgrep#readme) | Reproducible performance evidence, clear fit and limitations | Link measured overhead and explain benchmark scope in depth docs |
| [tldr-pages](https://github.com/tldr-pages/tldr#readme) | Starts from recognizable user frustration, then a small example | Name the pile-up of helpers without making users study process internals |
| [Pake](https://github.com/tw93/Pake#readme) | Product identity, concrete lightweight value, beginner/developer entry paths | Native macOS positioning, simple build/run, deeper development guide |
| [bat](https://github.com/sharkdp/bat#readme) | Memorable theme and screenshot-led features | Cohesive skull/flame identity; show before explaining |
| [Win11Debloat](https://github.com/Raphire/Win11Debloat#readme) | Plain-language payoff, screenshot, straightforward usage choices | Simple impact view, with deliberate cleanup authority in the guide |
| [dive](https://github.com/wagoodman/dive#readme) | Demo GIF immediately before a minimal command example | Preview, quick start, practical usage—in that order |
| [aider](https://github.com/Aider-AI/aider#readme) | Strong centered opening, screencast, benefits tied to agent workflows | Brand-led hero and an operator-focused explanation |
| [GitHub CLI](https://github.com/cli/cli#readme) | Familiar workflow placement, screenshot, concise documentation routing | Explain where BZ fits beside existing tools, not as a replacement supervisor |

## Deliberate choices

Use a local mascot, real native screenshots, a short GIF tour, four useful badges, a three-part benefit row, a quick source build, a small roadmap, and visible contribution/security links. Keep research, safety predicates, exhaustive usage, and raw validation detail out of the opening screenful.

Do not copy install counts, testimonials, star-history graphs, sponsors, release badges for nonexistent releases, or another project's speed claims. No borrowed logos, screenshots, or implementation code are included. The preview uses synthetic demo data and is labeled as such outside the app image. The brand should feel playful; the underlying behavior remains conservative.
