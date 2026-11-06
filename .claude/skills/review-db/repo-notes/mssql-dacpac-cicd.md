# Repo notes: mssql-dacpac-cicd

Facts about this repository that a review needs and can't see in the code. One bullet each, 40
words at most, ending with its source; 300 words for the file. `/review-db` reads this file, and
`/pr-ready` reads the "Production reads" entry for its data checks.

- **Production reads: none.** `demo/DemoDb` is a demo with no production database, so data-dependent findings stay "needs data check". A copy of this pipeline names its read-only SQL tool, server and database here. (src: README)
- **`demo/DemoDb` is SDK-style** (`Microsoft.Build.Sql`): every `.sql` under it builds without an `Include` item, so `Validate-SqlprojCoverage.ps1` warning about all of them is expected, not a finding. (src: README)
- **`global.json` pins the .NET 8 SDK**: `Microsoft.Build.Sql` 0.2.3-preview doesn't build on SDK 10, so dropping the pin breaks `ci.yml`'s build job. (src: ci.yml)
- **The generator workflow, deploy scripts and Jenkinsfiles target a project named `AppDb_Analytics` on `master`.** Their paths and branch not matching `demo/DemoDb` and `main` is the documented adaptation step, not a finding. (src: README "Adapting it")
