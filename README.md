# cursor-ios-workers

Let Cursor cloud agents build and test your iOS apps on your own Mac.

## What it does

Cursor cloud agents normally run on Linux machines in Cursor's cloud. Those machines can't run Xcode.

Cursor's My Machines feature fixes that. You start a small worker program on your Mac. The agent still thinks and plans in Cursor's cloud. Its terminal commands, file edits and builds run on your Mac. The worker connects out to Cursor over HTTPS. You don't need to open any ports.

This script sets that up for you. It finds every iOS repo in your home folder and starts a worker for each one. Agents for those repos can then run xcodebuild, Swift tests and the Simulator on your Mac.

Your other repos are not affected. Agents for them keep running in Cursor's cloud as usual.

## Requirements

- A Mac running macOS.
- Xcode, or the Command Line Tools for Xcode. The script needs git from one of them.
- The Cursor CLI, signed in to your Cursor account.
- A Cursor plan that includes cloud agents and My Machines. If you are on a team, a team admin may need to turn on "Allow Self-Hosted Machines" in the Cloud Agents dashboard.
- Your iOS repos must have a GitHub remote.

## Install

1. Install the Cursor CLI:

       curl https://cursor.com/install -fsS | bash

2. Sign in:

       agent login

   You can check it with "agent status".

3. Download this repo and make the script executable:

       git clone https://github.com/taylorarndt/cursor-ios-workers.git
       cd cursor-ios-workers
       chmod +x ios-workers.sh

The script never installs anything and never signs in for you. If the CLI is missing or you are signed out, it prints the command to run and stops.

## See what it would do

Run a dry run first:

    ./ios-workers.sh scan

This lists the iOS repos it found, any repos it skipped and why, and the machine name it would use. It changes nothing.

A repo counts as iOS if it has an .xcodeproj, an .xcworkspace, a Package.swift, or any .swift file.

The search goes up to 6 folders deep. It skips ~/Library, the Trash, hidden folders, node_modules, DerivedData, Pods, .build and Carthage.

## Leave repos out

Copy the example exclude file and edit it:

    mkdir -p ~/.config/ios-workers
    cp exclude.example ~/.config/ios-workers/exclude

Put one path per line. Lines starting with # are comments. Listing a folder also leaves out every repo inside it.

Run scan again to check the result.

## Start the workers

    ./ios-workers.sh start

This starts one background worker for each iOS repo. If a repo already has a running worker, it doesn't start a second one.

Logs go to ~/Library/Logs/ios-workers, one file per repo. Process IDs go to ~/.config/ios-workers/pids.

## Check the workers

    ./ios-workers.sh status

This lists the workers the script started and whether each one is running.

## Stop the workers

    ./ios-workers.sh stop

This stops only the workers the script started. Other processes are left alone.

## Settings

All settings are optional environment variables.

- IOS_WORKERS_NAME: the machine name. The default is your Mac's short hostname plus "-ios", in lowercase. For example, "my-macbook-pro-ios".
- IOS_WORKERS_MODE: "per-repo" is the default. It runs one worker per repo. "single" runs one worker that serves every repo. Run stop before you switch modes.
- IOS_WORKERS_MAX_DEPTH: how many folders deep to search. The default is 6.
- SEARCH_ROOT: the folder to search. The default is your home folder.

Example:

    IOS_WORKERS_NAME=studio-mac SEARCH_ROOT=~/Developer ./ios-workers.sh scan

## Send an agent to your Mac

The scan, start and status commands all print the machine name.

- On cursor.com/agents, pick your machine under My Machines in the menu that sets where the agent runs.
- In Slack, add machine=NAME to your request. For example: @Cursor machine=my-macbook-pro-ios fix the failing test
- On GitHub, comment: @cursoragent machine=my-macbook-pro-ios fix the failing test
- In Linear, add machine=NAME to the @Cursor comment that starts the run.

You can use worker=NAME instead of machine=NAME.

A request runs on your Mac only if all three of these are true:

- You are the one who asked.
- The machine name matches.
- The repo matches one of your workers.

If any of them doesn't match, Cursor rejects the request. It doesn't fall back to some other checkout.

Agents work in the checkouts already on your Mac. They don't clone or switch branches for you.

## Security notes

- Workers run as your macOS user. Agents can read and change anything your user can, including other files and your git credentials. Only start workers for repos you trust.
- Leave out repos that belong to other people, and forks of public projects. Use the exclude file.
- Don't run a worker for a repo where people you don't trust can trigger agents.
- Never commit tokens, keys or passwords. The script never prints or saves them, and it shows only "owner/repo" instead of remote URLs. Agents can still see files on your Mac, so keep secrets out of your repos and out of build logs.
- The script never uses sudo. It writes only to ~/.config/ios-workers and ~/Library/Logs/ios-workers.

## Limits and unconfirmed points

- Shared name: in per-repo mode, every worker uses the same name. Cursor's docs don't say whether several workers may share a name. If agents can't find your machine, try IOS_WORKERS_MODE=single. That mode passes every repo to one worker, which the docs describe directly.
- No automatic restart: workers stop when you log out or restart your Mac. Run start again afterward.
- Worktrees and submodules are skipped.
- Repos with no remote, or with a remote not on GitHub, are skipped. The script says why.
- Signed-in check: the script treats a failure from "agent status", or text like "not authenticated", as signed out. The exact output isn't documented.
- Cursor allows up to 200 workers per user. The script won't start more than that.

## Undo everything

1. Stop the workers:

       ./ios-workers.sh stop

2. Delete the script's folders:

       rm -rf ~/.config/ios-workers ~/Library/Logs/ios-workers

3. Delete this repo folder if you like.
4. To remove Cursor's sign-in from your Mac, run "agent logout".

## Troubleshooting

- Read the log for the repo in ~/Library/Logs/ios-workers.
- Run "agent worker debug". It checks sign-in, routing and whether Cursor can see your worker.
- Make sure the Cursor app and the CLI use the same account.

## Official Cursor docs

- My Machines: https://cursor.com/docs/cloud-agent/self-hosted/my-machines
- Self-Hosted Machines: https://cursor.com/docs/cloud-agent/self-hosted
- Self-Hosted Machines help: https://cursor.com/help/ai-features/self-hosted-machines
- CLI installation: https://cursor.com/docs/cli/installation
- CLI authentication: https://cursor.com/docs/cli/reference/authentication
- CLI parameters: https://cursor.com/docs/cli/reference/parameters
- Cloud agents: https://cursor.com/docs/cloud-agent

## License

MIT. See LICENSE.
