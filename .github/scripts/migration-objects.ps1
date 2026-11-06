# T-SQL object helpers shared by generate-migration-scripts.yml: the R__ builder and the
# object-order check dot-source this file, so both read SQL the same way.

# One name part: [bracketed] (]] escapes a bracket) or a plain identifier.
$SqlPart = '(?:\[(?:[^\]]|\]\])+\]|[A-Za-z_][\w$#@]*)'
# The name in a CREATE/DROP: looser, as SSDT allows any characters in brackets.
$SqlDefPart = '(?:\[(?:[^\]]|\]\])+\]|[^\s.\[\](),;]+)'
$SqlDefName = "$SqlDefPart(?:\s*\.\s*$SqlDefPart)?"
$sqlQuote = [char]39
# Comments (block comments nest in T-SQL), string literals, quoted identifiers.
$SqlLexRx = [regex]("--[^\n]*|/\*(?>/\*(?<d>)|\*/(?<-d>)|(?!/\*|\*/)[\s\S])*(?(d)(?!))\*/|(?:(?<!\w)N)?$sqlQuote(?:[^$sqlQuote]|$sqlQuote$sqlQuote)*$sqlQuote|\[(?:[^\]]|\]\])*\]|" + '"(?:[^"]|"")*"')

# The text with comments and string literals blanked, except dynamic SQL (EXEC('...'),
# sp_executesql N'...'), which runs. Lengths and line breaks are kept, so a position in
# the result is the same position in the text.
function Get-CodeView([string]$text) {
  $sb = New-Object System.Text.StringBuilder $text
  foreach ($m in $SqlLexRx.Matches($text)) {
    $v = $m.Value
    if ($v[0] -eq '[' -or $v[0] -eq '"') { continue }
    $keepFrom = $m.Length; $keepTo = -1
    if ($v[0] -ne '-' -and $v[0] -ne '/') {
      $start = [Math]::Max(0, $m.Index - 80)
      if ($text.Substring($start, $m.Index - $start) -match '(?i)(\bEXEC(UTE)?\s*\(\s*|\bsp_executesql\s+(@\w+\s*=\s*)?)$') { $keepFrom = $v.IndexOf($sqlQuote) + 1; $keepTo = $m.Length - 2 }
    }
    for ($i = 0; $i -lt $m.Length; $i++) {
      if ($i -ge $keepFrom -and $i -le $keepTo) { continue }
      if ($v[$i] -ne "`n" -and $v[$i] -ne "`r") { $sb[$m.Index + $i] = ' ' }
    }
  }
  $sb.ToString()
}

# [schema].[name] / schema.name / name -> its parts, brackets removed.
function Split-SqlName([string]$text) {
  @([regex]::Matches($text, '\[((?:[^\]]|\]\])+)\]|([^\s.\[\]]+)') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value -replace '\]\]', ']' } else { $_.Groups[2].Value } })
}
function ConvertTo-SqlKey([string]$text, [string]$defaultSchema = 'dbo') {
  $p = @(Split-SqlName $text)
  $schema = if ($p.Count -ge 2) { $p[-2] } else { $defaultSchema }
  @{ Schema = $schema; Name = $p[-1]; Key = "$schema.$($p[-1])".ToLowerInvariant() }
}

# A batch's first statement: where it starts, past whitespace and comments.
function Get-FirstStatement([string]$batch) {
  $code = Get-CodeView $batch
  $at = $code.Length - $code.TrimStart().Length
  if ($at -ge $code.Length) { return $null }
  @{ Prefix = $batch.Substring(0, $at); Text = $batch.Substring($at); Code = $code.Substring($at) }
}

# A trigger defined in a table file. CREATE TRIGGER must be the first statement of its
# batch, so such a batch is the whole trigger. Returns its schema (from the ON table when
# the name is unqualified), name and the batch as CREATE OR ALTER, or $null.
function Get-BatchTrigger([string]$batch, [string]$defaultSchema) {
  $fs = Get-FirstStatement $batch.Trim()
  if (-not $fs) { return $null }
  $m = [regex]::Match($fs.Code, "(?i)\ACREATE\s+(?:OR\s+ALTER\s+)?TRIGGER\s+(?<name>$SqlDefName)(?:\s+ON\s+(?<on>$SqlDefName))?")
  if (-not $m.Success) { return $null }
  $onSchema = if ($m.Groups['on'].Success -and @(Split-SqlName $m.Groups['on'].Value).Count -ge 2) { (ConvertTo-SqlKey $m.Groups['on'].Value).Schema } else { $defaultSchema }
  $n = ConvertTo-SqlKey $m.Groups['name'].Value $onSchema
  @{ Schema = $n.Schema; Name = $n.Name; Key = $n.Key
     Batch = $fs.Prefix + [regex]::Replace($fs.Text, '(?i)\ACREATE\s+TRIGGER\b', 'CREATE OR ALTER TRIGGER') }
}
function Get-TableTriggers([string]$content, [string]$defaultSchema) {
  foreach ($batch in ($content -split '(?m)^\s*GO\s*$')) {
    $t = Get-BatchTrigger $batch $defaultSchema
    if ($t) { $t }
  }
}

# The object a view/procedure/function/trigger file defines: the first batch whose first
# statement is CREATE [OR ALTER] VIEW/PROC/PROCEDURE/FUNCTION/TRIGGER. An unqualified name is
# dbo, as SSDT reads it (a trigger's is its table's schema).
function Get-DefinedObject([string]$content) {
  foreach ($batch in ($content -split '(?m)^\s*GO\s*$')) {
    $fs = Get-FirstStatement $batch.Trim()
    if (-not $fs) { continue }
    $m = [regex]::Match($fs.Code, "(?i)\ACREATE\s+(?:OR\s+ALTER\s+)?(?<kind>VIEW|PROCEDURE|PROC|FUNCTION|TRIGGER)\s+(?<name>$SqlDefName)(?:\s+ON\s+(?<on>$SqlDefName))?")
    if (-not $m.Success) { continue }
    $kind = if ($m.Groups['kind'].Value -like 'PROC*') { 'PROCEDURE' } else { $m.Groups['kind'].Value.ToUpperInvariant() }
    $default = if ($kind -eq 'TRIGGER' -and $m.Groups['on'].Success -and @(Split-SqlName $m.Groups['on'].Value).Count -ge 2) { (ConvertTo-SqlKey $m.Groups['on'].Value).Schema } else { 'dbo' }
    $n = ConvertTo-SqlKey $m.Groups['name'].Value $default
    return @{ Kind = $kind; Schema = $n.Schema; Name = $n.Name; Key = $n.Key; SchemaBound = ($fs.Code -match '(?i)\bSCHEMABINDING\b') }
  }
  return $null
}

# What a code view references, as schema.object keys with their positions: dotted names
# (db.schema.object when the first part is this database, otherwise schema.object(.column))
# and unqualified names after FROM/JOIN/APPLY/EXEC/INTO/UPDATE/REFERENCES or before "(",
# which resolve to dbo. Run it on Get-CodeView output.
$SqlChainRx = [regex]("(?<![\w\[@#$.\]])$SqlPart(?:\s*\.\s*$SqlPart){1,3}(?![\w$])")
$SqlBareRx = [regex]("(?i)\b(?:FROM|JOIN|APPLY|EXEC(?:UTE)?|INTO|UPDATE|REFERENCES)\s+(?<n>$SqlPart)(?![\w$])(?!\s*\.)|(?<![\w.\[\]@#$])(?<n>$SqlPart)(?=\s*\()")
function Get-SqlReferences([string]$code, [string]$database) {
  foreach ($m in $SqlChainRx.Matches($code)) {
    $p = @(Split-SqlName $m.Value)
    $key = $null
    if ($p.Count -eq 2) { $key = "$($p[0]).$($p[1])" }
    elseif ($p.Count -eq 3) { $key = if ($p[0] -ieq $database) { "$($p[1]).$($p[2])" } else { "$($p[0]).$($p[1])" } }
    elseif ($p.Count -eq 4 -and $p[0] -ieq $database) { $key = "$($p[1]).$($p[2])" }
    if ($key) { @{ Key = $key.ToLowerInvariant(); Pos = $m.Index; Bare = $false } }
  }
  foreach ($m in $SqlBareRx.Matches($code)) {
    $g = $m.Groups['n']
    @{ Key = "dbo.$(@(Split-SqlName $g.Value)[0])".ToLowerInvariant(); Pos = $g.Index; Bare = $true }
  }
}

# Must-precede: CREATE VIEW and CREATE FUNCTION resolve the views and functions they name
# when created, and a function must exist before anything that calls it. What else a
# procedure or trigger names is resolved at run time.
function Test-SqlMustPrecede([string]$fromKind, [string]$toKind) { $toKind -eq 'FUNCTION' -or ($toKind -eq 'VIEW' -and $fromKind -in @('VIEW', 'FUNCTION')) }

function ConvertTo-Ere([string]$s) { [regex]::Replace($s, '[\[\]\\.^$*+?(){}|]', '\$0') }
function Get-SqlNameRx([string]$schema, [string]$name) {
  '(?i)(?<![\w\[@#$])(?:\[' + [regex]::Escape($schema) + '\]|' + [regex]::Escape($schema) + ')\s*\.\s*(?:\[' + [regex]::Escape($name) + '\]|' + [regex]::Escape($name) + ')(?![\w$])'
}
# Files (at the merge base) that may name schema.name; a dbo object may also be named bare.
function Find-BaseFiles([string]$mergeBase, [string]$database, [string]$schema, [string]$name) {
  $patterns = @('-e', ('(^|[^A-Za-z0-9_@#$])\[?' + (ConvertTo-Ere $schema) + '\]?[[:space:]]*\.[[:space:]]*\[?' + (ConvertTo-Ere $name) + '\]?([^A-Za-z0-9_@#$]|$)'))
  if ($schema -ieq 'dbo') { $patterns += @('-e', ('(^|[^A-Za-z0-9_@#$.])\[?' + (ConvertTo-Ere $name) + '\]?([^A-Za-z0-9_@#$.]|$)')) }
  $hits = @(git grep -l -i -E @patterns $mergeBase -- "$database/*.sql" 2>$null)
  # git grep exits 1 for "no match"; anything else means the scan itself failed, and an
  # empty answer would read as "nothing depends on it"
  if ($LASTEXITCODE -gt 1) { Write-Host "::warning::Could not scan the merge base for users of $schema.$name (git grep exit $LASTEXITCODE) - its dependents are not checked" }
  foreach ($hit in $hits) { $hit.Substring($mergeBase.Length + 1) }
}

# What used a type at the merge base: procedures, functions, views and table triggers
# (Kind PROCEDURE/FUNCTION/VIEW/TRIGGER), other user-defined types (TYPE) and table
# columns (COLUMN, Key = the table).
function Get-TypeUsers([string]$mergeBase, [string]$database, [string]$schema, [string]$name) {
  if (-not $mergeBase) { return }
  $rx = Get-SqlNameRx $schema $name
  $n = [regex]::Escape($name)
  $bareRx = if ($schema -ieq 'dbo') { "(?i)@\w+\s+(?:AS\s+)?(?:\[$n\]|$n)(?![\w$.])|(?im)^\s*(?:\[[^\]]+\]|[\w$#@]+)\s+(?:\[$n\]|$n)(?![\w$.])" } else { $null }
  $self = "$schema.$name".ToLowerInvariant()
  foreach ($path in @(Find-BaseFiles $mergeBase $database $schema $name)) {
    $raw = (git cat-file -p "${mergeBase}:$path" 2>$null) -join "`n"
    $uses = { param($text) $c = Get-CodeView $text; ($c -match $rx) -or ($bareRx -and $c -match $bareRx) }
    if ($path -match '[/\\](Views|Stored Procedures?|Functions|Triggers)[/\\]') {
      $d = Get-DefinedObject $raw
      if ($d -and (& $uses $raw)) { @{ Kind = $d.Kind; Schema = $d.Schema; Name = $d.Name; Key = $d.Key; Path = $path } }
    } elseif ($path -match '[/\\]User Defined Types[/\\]') {
      $t = [regex]::Match((Get-CodeView $raw), "(?i)\bCREATE\s+TYPE\s+(?<n>$SqlDefName)")
      if (-not $t.Success) { continue }
      $tk = ConvertTo-SqlKey $t.Groups['n'].Value
      $rest = (Get-CodeView $raw).Remove($t.Index, $t.Length).Insert($t.Index, ' ' * $t.Length)
      if ($tk.Key -ne $self -and (($rest -match $rx) -or ($bareRx -and $rest -match $bareRx))) { @{ Kind = 'TYPE'; Schema = $tk.Schema; Name = $tk.Name; Key = $tk.Key; Path = $path } }
    } elseif ($path -match '([^/\\]+)[/\\]Tables[/\\]') {
      $tableSchema = $matches[1]
      $owner = [regex]::Match((Get-CodeView $raw), "(?i)\bCREATE\s+TABLE\s+(?<n>$SqlDefName)")
      foreach ($b in ($raw -split '(?m)^\s*GO\s*$')) {
        if (-not (& $uses $b)) { continue }
        $tr = Get-BatchTrigger $b $tableSchema
        if ($tr) { @{ Kind = 'TRIGGER'; Schema = $tr.Schema; Name = $tr.Name; Key = $tr.Key; Path = $path } }
        elseif ($owner.Success) { $ok = ConvertTo-SqlKey $owner.Groups['n'].Value; @{ Kind = 'COLUMN'; Schema = $ok.Schema; Name = $ok.Name; Key = $ok.Key; Path = $path } }
      }
    }
  }
}

# Foreign keys (at the merge base) from other tables to schema.name: table-level, column-
# level and unnamed (Constraint = ''), with the table that owns each.
function Get-ForeignKeysTo([string]$mergeBase, [string]$database, [string]$schema, [string]$name) {
  if (-not $mergeBase) { return }
  $target = "$schema.$name".ToLowerInvariant()
  $fkRx = [regex]("(?is)(?:\bCONSTRAINT\s+(?<c>$SqlDefPart)\s+)?(?:FOREIGN\s+KEY\s*\([^)]*\)\s*)?\bREFERENCES\s+(?<t>$SqlDefName)")
  foreach ($path in @(Find-BaseFiles $mergeBase $database $schema $name)) {
    if ($path -notmatch '[/\\]Tables[/\\]') { continue }
    $code = Get-CodeView ((git cat-file -p "${mergeBase}:$path" 2>$null) -join "`n")
    $tables = @([regex]::Matches($code, "(?i)\b(?:CREATE|ALTER)\s+TABLE\s+(?<n>$SqlDefName)"))
    foreach ($fk in $fkRx.Matches($code)) {
      if ((ConvertTo-SqlKey $fk.Groups['t'].Value).Key -ne $target) { continue }
      $own = $null; foreach ($t in $tables) { if ($t.Index -lt $fk.Index) { $own = $t } }
      if (-not $own) { continue }
      $ownerKey = (ConvertTo-SqlKey $own.Groups['n'].Value).Key
      if ($ownerKey -eq $target) { continue }
      @{ Owner = $ownerKey; Constraint = $(if ($fk.Groups['c'].Success) { @(Split-SqlName $fk.Groups['c'].Value)[0] } else { '' }); Path = $path }
    }
  }
}
