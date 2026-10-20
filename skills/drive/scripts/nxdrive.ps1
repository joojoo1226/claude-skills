#requires -Version 5.1
<#
    nxdrive.ps1 - Nextcloud Drive (Nextcloud) access helper for Claude Code.

    All messages in this file are intentionally ASCII-only: Windows PowerShell 5.1
    reads BOM-less .ps1 files as ANSI, so non-ASCII literals here would corrupt.
    Korean file names coming back from the server are handled correctly because
    they travel as UTF-8 over HTTP and console output is forced to UTF-8 below.

    Output contract: a single JSON object on stdout.
      success -> { "ok": true,  "action": "...", ... }
      failure -> { "ok": false, "error": "...", "hint": "..." }   (exit code 1)
#>
[CmdletBinding()]
param(
    [ValidateSet('login', 'logout', 'test', 'providers', 'search', 'recent', 'ls', 'get')]
    [string]$Action = 'search',

    [string]$Query = '',
    [string]$Path = '/',
    [int]$Limit = 25,

    [ValidateSet('auto', 'unified', 'webdav')]
    [string]$Mode = 'auto',

    [string[]]$Ext = @(),
    [int]$Depth = 1,
    [string]$Out = '',

    [string]$User = '',
    [string]$AppPassword = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BaseUrl = if ($env:NXDRIVE_URL) { $env:NXDRIVE_URL.TrimEnd('/') } else { 'https://nextcloud.example.com' }
$CredDir = Join-Path $env:USERPROFILE '.claude\.nxdrive'
$CredPath = Join-Path $CredDir 'credential.xml'

# Extension filtering, and "recent" dropping folders, both happen client-side.
# Ask the server for a wider pool in those cases, or "-Limit 6" returns whatever
# few rows survive the filter instead of 6 actual hits.
$ExtActive = @(@($Ext) -join ',' -split ',' | Where-Object { $_.Trim() }).Count -gt 0
$FetchLimit = if ($ExtActive -or $Action -eq 'recent') {
    [Math]::Min([Math]::Max($Limit * 20, 100), 500)
} else { $Limit }

# ---------------------------------------------------------------- output ----

# Write straight to the console instead of the pipeline. Helper functions are
# called inside captures like @(Search-Webdav ...), which would otherwise swallow
# a Fail message into that variable and exit 1 with no output at all.
function Emit {
    param([string]$Text)
    [Console]::Out.WriteLine($Text)
    [Console]::Out.Flush()
}

function Write-Result {
    param([hashtable]$Data)
    $Data['ok'] = $true
    $Data['action'] = $Action
    Emit ($Data | ConvertTo-Json -Depth 10)
}

function Fail {
    param([string]$Message, [string]$Hint = '')
    $o = [ordered]@{ ok = $false; action = $Action; error = $Message }
    if ($Hint) { $o['hint'] = $Hint }
    Emit (([pscustomobject]$o) | ConvertTo-Json -Depth 4)
    exit 1
}

# ------------------------------------------------------------ credentials ----

function Get-NxDriveCredential {
    if ($env:NXDRIVE_USER -and $env:NXDRIVE_APP_PASSWORD) {
        return [pscustomobject]@{
            User     = $env:NXDRIVE_USER
            Password = $env:NXDRIVE_APP_PASSWORD
            Source   = 'env'
        }
    }
    if (-not (Test-Path $CredPath)) {
        Fail 'No stored Nextcloud Drive credential.' `
            "Run: & `"$PSCommandPath`" -Action login -User <id> -AppPassword <app-password>"
    }
    $cred = Import-Clixml -Path $CredPath
    return [pscustomobject]@{
        User     = $cred.UserName
        Password = $cred.GetNetworkCredential().Password
        Source   = 'store'
    }
}

# ----------------------------------------------------------------- http -----

function New-Client {
    param([pscustomobject]$Credential)
    Add-Type -AssemblyName System.Net.Http | Out-Null
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(90)

    $raw = '{0}:{1}' -f $Credential.User, $Credential.Password
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw))
    $client.DefaultRequestHeaders.Authorization =
        New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Basic', $b64)
    $client.DefaultRequestHeaders.Add('OCS-APIRequest', 'true')
    $client.DefaultRequestHeaders.Add('User-Agent', 'claude-code-nxdrive/1.0')
    return $client
}

function Invoke-Dav {
    param(
        [System.Net.Http.HttpClient]$Client,
        [string]$Method,
        [string]$Uri,
        [string]$Body = '',
        [hashtable]$Headers = @{}
    )
    $verb = New-Object System.Net.Http.HttpMethod -ArgumentList $Method
    $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList $verb, $Uri
    foreach ($k in $Headers.Keys) { $req.Headers.Add($k, $Headers[$k]) }
    if ($Body) {
        $req.Content = New-Object System.Net.Http.StringContent(
            $Body, [System.Text.Encoding]::UTF8, 'application/xml')
    }
    $resp = $Client.SendAsync($req).Result
    return $resp
}

function Read-Text {
    param([System.Net.Http.HttpResponseMessage]$Response)
    $bytes = $Response.Content.ReadAsByteArrayAsync().Result
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Assert-Ok {
    param([System.Net.Http.HttpResponseMessage]$Response, [string]$What)
    $code = [int]$Response.StatusCode
    if ($code -ge 200 -and $code -lt 300) { return }
    $hint = ''
    if ($code -eq 401) { $hint = 'Credential rejected. Re-run -Action login with a fresh app password.' }
    elseif ($code -eq 404) { $hint = 'Path not found on the server. Check the folder or file name.' }
    elseif ($code -eq 403) { $hint = 'Access denied for this account.' }
    Fail ("{0} failed: HTTP {1} {2}" -f $What, $code, $Response.ReasonPhrase) $hint
}

# ------------------------------------------------------------ path utils ----

function ConvertTo-DavPath {
    param([string]$P)
    $clean = ($P -replace '\\', '/').Trim()
    if (-not $clean.StartsWith('/')) { $clean = '/' + $clean }
    $segments = $clean.Split('/') | Where-Object { $_ -ne '' }
    if (-not $segments) { return '' }
    return '/' + (($segments | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/')
}

function Get-FilesRoot {
    param([string]$UserName)
    return '/remote.php/dav/files/' + [System.Uri]::EscapeDataString($UserName)
}

function Test-ExtMatch {
    param([string]$Name)
    # Accepts -Ext xlsx,pdf (bound as an array) and -Ext 'xlsx, pdf' (single string) alike.
    if (-not $Ext -or @($Ext).Count -eq 0) { return $true }
    $wanted = @(@($Ext) -join ',' -split ',' |
        ForEach-Object { $_.Trim().TrimStart('.').ToLower() } | Where-Object { $_ })
    if (-not $wanted) { return $true }
    $actual = [System.IO.Path]::GetExtension($Name).TrimStart('.').ToLower()
    return $wanted -contains $actual
}

# --------------------------------------------------------- dav xml parse ----

function ConvertFrom-Multistatus {
    param([string]$Xml, [string]$FilesRoot)

    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xml)
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('d', 'DAV:')
    $ns.AddNamespace('oc', 'http://owncloud.org/ns')
    $ns.AddNamespace('nc', 'http://nextcloud.org/ns')

    $items = @()
    foreach ($r in $doc.SelectNodes('//d:response', $ns)) {
        $href = $r.SelectSingleNode('d:href', $ns).InnerText
        $prop = $r.SelectSingleNode("d:propstat[contains(d:status,' 200 ')]/d:prop", $ns)
        if (-not $prop) { continue }

        $isDir = $null -ne $prop.SelectSingleNode('d:resourcetype/d:collection', $ns)

        # href is percent-encoded and server-absolute; turn it into a user-relative path
        $rel = [System.Uri]::UnescapeDataString($href)
        $rootPlain = [System.Uri]::UnescapeDataString($FilesRoot)
        if ($rel.StartsWith($rootPlain)) { $rel = $rel.Substring($rootPlain.Length) }
        $rel = $rel.TrimEnd('/')
        if (-not $rel) { $rel = '/' }

        $name = Split-Path $rel -Leaf
        if (-not $name) { $name = '/' }
        if ($rel -eq '/') { continue }   # the queried folder itself

        $get = { param($n) $x = $prop.SelectSingleNode($n, $ns); if ($x) { $x.InnerText } else { $null } }

        $size = if ($isDir) { & $get 'oc:size' } else { & $get 'd:getcontentlength' }
        $mtimeRaw = & $get 'd:getlastmodified'
        $mtime = $null
        if ($mtimeRaw) {
            try { $mtime = ([DateTime]::Parse($mtimeRaw)).ToString('yyyy-MM-dd HH:mm') } catch { $mtime = $mtimeRaw }
        }

        $items += [pscustomobject]@{
            name     = $name
            path     = $rel
            type     = if ($isDir) { 'dir' } else { 'file' }
            size     = if ($size) { [long]$size } else { $null }
            modified = $mtime
            mime     = & $get 'd:getcontenttype'
            fileid   = & $get 'oc:fileid'
            url      = "$BaseUrl/index.php/apps/files/files/" + (& $get 'oc:fileid')
        }
    }
    return $items
}

# ---------------------------------------------------------------- actions ---

function Do-Login {
    # When run from a real console without -User/-AppPassword, ask for them here.
    # This avoids shell quoting problems and keeps the password out of command history.
    $interactive = [Environment]::UserInteractive
    if ($interactive -and (-not $User -or -not $AppPassword)) {
        Write-Host ''
        Write-Host '===== Nextcloud Drive login =====' -ForegroundColor Cyan
        Write-Host 'App password page: https://nextcloud.example.com/settings/user/security'
        Write-Host ''
        if (-not $User) { $User = (Read-Host 'Username (as shown on the app-password screen)').Trim() }
        if (-not $AppPassword) {
            $secIn = Read-Host 'App password (typing is hidden)' -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secIn)
            try { $AppPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr).Trim() }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        Write-Host ''
        Write-Host 'Contacting nextcloud.example.com ...'
    }

    if (-not $User -or -not $AppPassword) {
        Fail 'Both -User and -AppPassword are required for login.' `
            'Create an app password at https://nextcloud.example.com/settings/user/security'
    }
    $probe = New-Client ([pscustomobject]@{ User = $User; Password = $AppPassword })
    $resp = Invoke-Dav $probe 'GET' "$BaseUrl/ocs/v2.php/cloud/user?format=json"
    if ([int]$resp.StatusCode -eq 401) {
        Fail 'Server rejected these credentials (401).' 'Use an app password, not your login password.'
    }
    Assert-Ok $resp 'Login probe'

    if (-not (Test-Path $CredDir)) { New-Item -ItemType Directory -Path $CredDir -Force | Out-Null }
    $sec = ConvertTo-SecureString $AppPassword -AsPlainText -Force
    (New-Object System.Management.Automation.PSCredential($User, $sec)) | Export-Clixml -Path $CredPath

    $data = (Read-Text $resp | ConvertFrom-Json).ocs.data
    if ($interactive) {
        Write-Host ''
        Write-Host ('  SUCCESS - connected as {0} ({1})' -f $data.id, $data.displayname) -ForegroundColor Green
        Write-Host ('  Credential saved: {0}' -f $CredPath)
        Write-Host '  Done. Close this window and tell Claude Code it is registered.'
        Write-Host ''
    }
    Write-Result @{
        stored      = $CredPath
        user        = $data.id
        displayname = $data.displayname
        quota       = $data.quota
        note        = 'Credential encrypted with Windows DPAPI (this user + this machine only).'
    }
}

function Do-Logout {
    if (Test-Path $CredPath) { Remove-Item $CredPath -Force }
    Write-Result @{ removed = $CredPath }
}

function Do-Test {
    param($Client, $Cred)
    $resp = Invoke-Dav $Client 'GET' "$BaseUrl/ocs/v2.php/cloud/user?format=json"
    Assert-Ok $resp 'whoami'
    $d = (Read-Text $resp | ConvertFrom-Json).ocs.data
    Write-Result @{
        server      = $BaseUrl
        user        = $d.id
        displayname = $d.displayname
        email       = $d.email
        quota       = $d.quota
        credSource  = $Cred.Source
    }
}

function Get-Providers {
    param($Client)
    $resp = Invoke-Dav $Client 'GET' "$BaseUrl/ocs/v2.php/search/providers?format=json"
    Assert-Ok $resp 'Provider listing'
    return (Read-Text $resp | ConvertFrom-Json).ocs.data
}

function Do-Providers {
    param($Client)
    $p = Get-Providers $Client
    Write-Result @{
        count     = @($p).Count
        providers = @($p | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; order = $_.order } })
    }
}

function Search-Unified {
    param($Client, [string]$Term)

    $providers = Get-Providers $Client
    $wanted = @($providers | Where-Object {
        $_.id -eq 'files' -or $_.id -match 'fulltext' -or $_.id -match '^files'
    })
    if (-not $wanted) { $wanted = @($providers | Where-Object { $_.id -match 'file' }) }

    $hits = @()
    foreach ($p in $wanted) {
        $uri = '{0}/ocs/v2.php/search/providers/{1}/search?term={2}&limit={3}&format=json' -f `
            $BaseUrl, [System.Uri]::EscapeDataString($p.id), [System.Uri]::EscapeDataString($Term), $FetchLimit
        $resp = Invoke-Dav $Client 'GET' $uri
        if ([int]$resp.StatusCode -ne 200) { continue }
        $data = (Read-Text $resp | ConvertFrom-Json).ocs.data
        foreach ($e in @($data.entries)) {
            $path = $null
            if ($e.attributes) {
                if ($e.attributes.path) { $path = $e.attributes.path }
                elseif ($e.attributes.PSObject.Properties['path']) { $path = $e.attributes.path }
            }
            if (-not $path -and $e.subline) { $path = $e.subline }
            $hits += [pscustomobject]@{
                name     = $e.title
                path     = $path
                folder   = $e.subline
                url      = $e.resourceUrl
                provider = $p.id
            }
        }
    }
    return $hits
}

function Search-Webdav {
    param($Client, $Cred, [string]$Term, [string]$Scope, [switch]$RecentOnly)

    $scopeHref = '/files/' + $Cred.User + (($Scope -replace '\\', '/').TrimEnd('/'))
    if ($Scope -eq '/' -or -not $Scope) { $scopeHref = '/files/' + $Cred.User }

    # Nextcloud answers HTTP 500 (TypeError) when <d:where> is missing entirely,
    # so "recent" sends a match-everything pattern rather than dropping the clause.
    $pattern = if ($RecentOnly) { '%' }
               else { '%' + [System.Security.SecurityElement]::Escape($Term) + '%' }
    $where = @"
  <d:where>
    <d:like>
      <d:prop><d:displayname/></d:prop>
      <d:literal>$pattern</d:literal>
    </d:like>
  </d:where>
"@

    $body = @"
<?xml version="1.0" encoding="UTF-8"?>
<d:searchrequest xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
 <d:basicsearch>
  <d:select>
   <d:prop>
    <d:displayname/><d:getcontenttype/><d:getlastmodified/><d:getcontentlength/>
    <d:resourcetype/><oc:fileid/><oc:size/>
   </d:prop>
  </d:select>
  <d:from>
   <d:scope>
    <d:href>$([System.Security.SecurityElement]::Escape($scopeHref))</d:href>
    <d:depth>infinity</d:depth>
   </d:scope>
  </d:from>
$where
  <d:orderby>
   <d:order><d:prop><d:getlastmodified/></d:prop><d:descending/></d:order>
  </d:orderby>
  <d:limit><d:nresults>$FetchLimit</d:nresults></d:limit>
 </d:basicsearch>
</d:searchrequest>
"@

    $resp = Invoke-Dav $Client 'SEARCH' "$BaseUrl/remote.php/dav/" $body
    Assert-Ok $resp 'WebDAV SEARCH'
    return ConvertFrom-Multistatus (Read-Text $resp) (Get-FilesRoot $Cred.User)
}

function Do-Search {
    param($Client, $Cred)
    if (-not $Query) { Fail 'Missing -Query.' 'Example: -Action search -Query "2026 budget"' }

    # Unified search has no notion of a folder scope, so a scoped query must use WebDAV.
    $scoped = ($Path -and $Path -ne '/')
    $used = ''
    $hits = @()

    if ($Mode -eq 'unified' -or ($Mode -eq 'auto' -and -not $scoped)) {
        $hits = @(Search-Unified $Client $Query | Where-Object { Test-ExtMatch $_.name })
        $used = 'unified'
    }
    if ($Mode -eq 'webdav' -or ($Mode -eq 'auto' -and ($scoped -or $hits.Count -eq 0))) {
        $hits = @(Search-Webdav $Client $Cred $Query $Path | Where-Object { Test-ExtMatch $_.name })
        $used = 'webdav'
    }

    $hits = @($hits | Select-Object -First $Limit)

    Write-Result @{
        query   = $Query
        scope   = $Path
        method  = $used
        count   = $hits.Count
        results = $hits
    }
}

function Do-Recent {
    param($Client, $Cred)
    $hits = @(Search-Webdav $Client $Cred '' $Path -RecentOnly)
    $hits = @($hits | Where-Object { $_.type -eq 'file' -and (Test-ExtMatch $_.name) } | Select-Object -First $Limit)
    Write-Result @{ scope = $Path; count = $hits.Count; results = $hits }
}

function Do-Ls {
    param($Client, $Cred)
    $uri = $BaseUrl + (Get-FilesRoot $Cred.User) + (ConvertTo-DavPath $Path)
    $body = @'
<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
 <d:prop>
  <d:displayname/><d:getcontenttype/><d:getlastmodified/><d:getcontentlength/>
  <d:resourcetype/><oc:fileid/><oc:size/>
 </d:prop>
</d:propfind>
'@
    $resp = Invoke-Dav $Client 'PROPFIND' $uri $body @{ Depth = "$Depth" }
    Assert-Ok $resp 'PROPFIND'
    $items = @(ConvertFrom-Multistatus (Read-Text $resp) (Get-FilesRoot $Cred.User))
    $items = @($items | Where-Object { Test-ExtMatch $_.name } |
        Sort-Object @{ e = { $_.type -ne 'dir' } }, name)
    Write-Result @{ path = $Path; count = $items.Count; entries = $items }
}

function Do-Get {
    param($Client, $Cred)
    if ($Path -eq '/' ) { Fail 'Missing -Path.' 'Example: -Action get -Path "/Team/report.xlsx"' }

    $uri = $BaseUrl + (Get-FilesRoot $Cred.User) + (ConvertTo-DavPath $Path)
    $resp = Invoke-Dav $Client 'GET' $uri
    Assert-Ok $resp 'Download'

    $dest = $Out
    if (-not $dest) {
        $dir = Join-Path $env:TEMP 'nxdrive'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $leaf = Split-Path ($Path -replace '\\', '/') -Leaf
        $safe = ($leaf.ToCharArray() | ForEach-Object {
            if ([System.IO.Path]::GetInvalidFileNameChars() -contains $_) { '_' } else { $_ }
        }) -join ''
        $dest = Join-Path $dir $safe
    }
    $bytes = $resp.Content.ReadAsByteArrayAsync().Result
    [System.IO.File]::WriteAllBytes($dest, $bytes)

    $ext = [System.IO.Path]::GetExtension($dest).TrimStart('.').ToLower()
    $textLike = @('txt', 'md', 'csv', 'json', 'xml', 'yml', 'yaml', 'log', 'html', 'htm',
                  'ps1', 'py', 'js', 'ts', 'java', 'sql', 'sh', 'ini', 'conf')
    Write-Result @{
        remote    = $Path
        localPath = $dest
        bytes     = $bytes.Length
        mime      = $resp.Content.Headers.ContentType.MediaType
        readable  = ($textLike -contains $ext)
    }
}

# ------------------------------------------------------------------ main ----

try {
    if ($Action -eq 'login') { Do-Login; exit 0 }
    if ($Action -eq 'logout') { Do-Logout; exit 0 }

    $cred = Get-NxDriveCredential
    $client = New-Client $cred

    switch ($Action) {
        'test'      { Do-Test $client $cred }
        'providers' { Do-Providers $client }
        'search'    { Do-Search $client $cred }
        'recent'    { Do-Recent $client $cred }
        'ls'        { Do-Ls $client $cred }
        'get'       { Do-Get $client $cred }
    }
    exit 0
}
catch {
    Fail $_.Exception.Message ($_.ScriptStackTrace -split "`n" | Select-Object -First 1)
}
