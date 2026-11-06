"""Collect what /review-db must know about a pull request before it reviews it.

usage: python -I pr_context.py <owner/repo> <number> [clone-dir]

Prints Markdown. The "Signals" section comes first: one line per condition, starting with STOP or
NOTE, which SKILL.md step 2 acts on. Then the PR's facts, the author's commits since the last
review, linked PRs, the description, reviews, inline threads and PR comments: the raw material of
the ledger. With a clone directory it also compares the local branch with the PR head.

Read-only: it runs `gh` and `git` and writes nothing. Exit code 2 when gh can't answer, because a
review without its ledger would repeat settled points.

REVIEW_DB_IGNORE, when set, is a regular expression: PR comments it matches (a bot's status
comment, say) are left out of the output.
"""
import json
import os
import re
import subprocess
import sys

# Written by /review-db at the end of every comment it posts: the head it reviewed.
MARKER = re.compile(r"<!-- review-db head=([0-9a-f]{40}) -->")
# Same-repo "#12", cross-repo "owner/repo#12", and full pull-request URLs.
LINK = re.compile(r"(?:https://github\.com/([\w.-]+/[\w.-]+)/pull/|(?<![\w/])([\w.-]+/[\w.-]+)?#)(\d+)\b")

FACTS = """query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){
pullRequest(number:$number){title url state isDraft body headRefName headRefOid baseRefName author{login}}}}"""

# connection name -> the fields of each node
CONNECTIONS = {
    "reviewThreads": "path line originalLine isOutdated isResolved resolvedBy{login} "
                     "comments(first:100){nodes{databaseId createdAt author{login} originalCommit{oid} body}}",
    "reviews": "databaseId state author{login} body submittedAt commit{oid}",
    "comments": "databaseId author{login} body createdAt",
}


class GhError(Exception):
    pass


class GhCli:
    """The gh calls this script makes. Tests replace it with canned answers."""

    @staticmethod
    def args(query, variables):
        # Strings go with -f, so a repository named "2024" or "true" isn't sent as a number.
        out = ["gh", "api", "graphql", "-f", "query=" + query]
        for key, value in variables.items():
            if value is not None:
                out += ["-F" if isinstance(value, int) else "-f", f"{key}={value}"]
        return out

    def graphql(self, query, what, **variables):
        done = subprocess.run(self.args(query, variables), capture_output=True, text=True, encoding="utf-8")
        if done.returncode != 0:
            raise GhError(f"gh couldn't read {what}: {done.stderr.strip() or f'exit code {done.returncode}'}")
        return json.loads(done.stdout)["data"]["repository"]["pullRequest"]


def page_query(connection):
    return ("query($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){"
            f"pullRequest(number:$number){{{connection}(first:100,after:$after){{"
            f"pageInfo{{hasNextPage endCursor}} nodes{{{CONNECTIONS[connection]}}}}}}}}}}}")


def every_node(gh, connection, owner, name, number):
    nodes, after = [], None
    while True:
        page = gh.graphql(page_query(connection), f"the PR's {connection}",
                          owner=owner, name=name, number=number, after=after)[connection]
        nodes += page["nodes"]
        if not page["pageInfo"]["hasNextPage"]:
            return nodes
        after = page["pageInfo"]["endCursor"]


class Clone:
    def __init__(self, path):
        self.path = path

    def git(self, *args):
        """stdout, or None when git fails: a failure must not read as an empty answer."""
        done = subprocess.run(["git", *args], cwd=self.path, capture_output=True, text=True, encoding="utf-8")
        return done.stdout.strip() if done.returncode == 0 else None


def who(node):
    # GitHub returns no author for a deleted account and shows it as "ghost".
    return ((node or {}).get("author") or {}).get("login") or "ghost"


def clip(text, limit):
    text = MARKER.sub("", text or "").strip()
    return text if len(text) <= limit else text[:limit] + " [...]"


def last_review(threads, reviews, comments):
    """(time, sha) of the newest marker anywhere on the PR, or None."""
    stamped = [(c["createdAt"], c["body"]) for t in threads for c in t["comments"]["nodes"]]
    stamped += [(r["submittedAt"] or "", r["body"]) for r in reviews]
    stamped += [(c["createdAt"], c["body"]) for c in comments]
    found = [(at, m.group(1)) for at, body in stamped for m in [MARKER.search(body or "")] if m]
    return max(found) if found else None


def linked(body, slug, number):
    refs = []
    for url_repo, short_repo, n in LINK.findall(body or ""):
        ref = f"{url_repo or short_repo or slug}#{n}"
        if ref != f"{slug}#{number}" and ref not in refs:
            refs.append(ref)
    return refs


def local_signals(clone, pr, number, last):
    """Signals and commit lines from comparing the clone with the PR."""
    signals, commits = [], None
    head, base, branch = pr["headRefOid"], pr["baseRefName"], pr["headRefName"]
    if last and last != head:
        if clone.git("fetch", "-q", "origin", f"pull/{number}/head", base) is None:
            signals.append(f"NOTE fetch-failed: git fetch of the PR head and {base} failed, so the clone may be stale.")
        log = clone.git("log", "--no-merges", "--reverse", "--format=%h %s", f"{last}..{head}", "--not", f"origin/{base}")
        if log is None:
            signals.append(f"NOTE no-incremental: the commits from {last[:7]} to {head[:7]} can't be listed (a force-push, "
                           "or objects the clone lacks): review the whole PR, as on a first review.")
        elif not log:
            signals.append(f"STOP base-merges-only: every commit since {last[:7]} merges {base} in, so the PR's own "
                           "change hasn't moved.")
        else:
            commits = log.splitlines()
    mine = clone.git("rev-parse", "--verify", "-q", f"refs/heads/{branch}")
    if mine and mine != head:
        if clone.git("merge-base", "--is-ancestor", head, mine) is not None:
            ahead = clone.git("rev-list", "--count", f"{head}..{mine}")
            signals.append(f"STOP unpushed: local {branch} is {ahead} commit(s) ahead of the PR head.")
        else:
            signals.append(f"NOTE diverged: local {branch} isn't the PR head (an old or rebased copy); review the PR head.")
    if clone.git("rev-parse", "--abbrev-ref", "HEAD") == branch and clone.git("status", "--porcelain", "--untracked-files=no"):
        signals.append(f"STOP uncommitted: {branch} is checked out with uncommitted changes.")
    return signals, commits


def report(slug, number, clone_dir=None, gh=None):
    gh = gh or GhCli()
    owner, name = slug.split("/", 1)
    pr = gh.graphql(FACTS, "the PR", owner=owner, name=name, number=number)
    threads = every_node(gh, "reviewThreads", owner, name, number)
    reviews = every_node(gh, "reviews", owner, name, number)
    comments = every_node(gh, "comments", owner, name, number)
    ignore = re.compile(os.environ["REVIEW_DB_IGNORE"]) if os.environ.get("REVIEW_DB_IGNORE") else None

    head = pr["headRefOid"]
    stamp = last_review(threads, reviews, comments)
    last = stamp[1] if stamp else None
    signals, commits = [], None
    if pr["state"] != "OPEN":
        signals.append(f"NOTE closed: the PR is {pr['state'].lower()}; review it only if the developer named it, and never post.")
    if last == head:
        signals.append(f"STOP head-unchanged: the last review was of the current head, {head[:7]}.")
    elif clone_dir:
        more, commits = local_signals(Clone(clone_dir), pr, number, last)
        signals += more

    out = [f"# {slug}#{number}: {pr['title']}", "", "## Signals", ""]
    out += [f"- {s}" for s in signals] or ["- none"]
    out += ["", "## Facts", "",
            f"- status: {pr['state'].lower()}{', draft' if pr['isDraft'] else ''}",
            f"- opened by: {who(pr)}",
            f"- branches: {pr['headRefName']} into {pr['baseRefName']}",
            f"- head sha: {head}",
            f"- last reviewed head: {f'{last} ({stamp[0][:10]})' if last else 'none, so this is a first review'}"]
    if commits is not None:
        out += ["", f"## Author commits since the last review ({len(commits)})", ""]
        out += [f"- {c}" for c in commits]
    refs = linked(pr["body"], slug, number)
    if refs:
        out += ["", "## Linked PRs and issues", ""] + [f"- {r}" for r in refs]
    out += ["", "## Description", "", clip(pr["body"], 6000) or "(empty)"]

    shown = [r for r in reviews if (r["body"] or "").strip() or r["state"] in ("APPROVED", "CHANGES_REQUESTED")]
    out += ["", f"## Reviews ({len(shown)})", ""]
    for r in shown:
        sha = ((r.get("commit") or {}).get("oid") or "")[:7]
        out += [f"### {r['state'].lower()} by {who(r)} at {sha} {(r['submittedAt'] or '')[:10]}",
                clip(r["body"], 1500) or "(no text)", ""]

    out += [f"## Inline threads ({len(threads)})", ""]
    for t in threads:
        first, *replies = t["comments"]["nodes"] or [None]
        if not first:
            continue
        label = "open"
        if t["isResolved"]:
            label = f"resolved by {((t.get('resolvedBy') or {}).get('login')) or 'ghost'}"
            if not replies:
                label += " without a reply"
        if t["isOutdated"]:
            label += ", outdated"
        sha = ((first.get("originalCommit") or {}).get("oid") or "")[:7]
        out += [f"### {label}: {t['path']}:{t['line'] or t['originalLine']} id={first['databaseId']} "
                f"by {who(first)} at {sha} {first['createdAt'][:10]}", clip(first["body"], 1500)]
        out += [f"- reply by {who(r)} {r['createdAt'][:10]}: {clip(r['body'], 800)}" for r in replies]
        out.append("")

    kept = [c for c in comments if not (ignore and ignore.search(c["body"] or ""))]
    out += [f"## PR comments ({len(kept)})", ""]
    for c in kept:
        out += [f"### by {who(c)} {c['createdAt'][:10]} id={c['databaseId']}", clip(c["body"], 800), ""]
    return "\n".join(out).rstrip() + "\n"


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) not in (2, 3) or "/" not in argv[0] or not argv[1].isdigit():
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        return 2
    sys.stdout.reconfigure(encoding="utf-8")
    try:
        sys.stdout.write(report(argv[0], int(argv[1]), argv[2] if len(argv) == 3 else None))
    except GhError as e:
        sys.stderr.write(f"pr_context.py: {e}\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
