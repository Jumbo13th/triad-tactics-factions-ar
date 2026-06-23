[CmdletBinding()]
param(
    [string]$CharactersPrefabsDirectory = "Prefabs/Characters/Factions",
    [string]$GroupsPrefabsDirectory = "Prefabs/Groups",
    [string]$CharactersMetaDirectory = "UI/Textures/EditorPreviews/Characters/Factions",
    [string]$GroupsMetaDirectory = "UI/Textures/EditorPreviews/Groups",
    [string]$NameSuffix = "_BCR",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $Path))
}

function Get-NormalizedRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $relativePath = [System.IO.Path]::GetRelativePath($BasePath, $TargetPath)
    if ($relativePath -eq ".") {
        return ""
    }

    return ($relativePath -replace "\\", "/")
}

function Get-LeadingWhitespace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    if ($Text -match '^\s*') {
        return $Matches[0]
    }

    return ""
}

function Get-BraceDelta {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $openCount = [regex]::Matches($Line, '\{').Count
    $closeCount = [regex]::Matches($Line, '\}').Count
    return $openCount - $closeCount
}

function Get-ResourceReferenceFromMeta {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MetaPath
    )

    if (-not (Test-Path -Path $MetaPath -PathType Leaf)) {
        return $null
    }

    $content = Get-Content -Path $MetaPath -Raw
    $nameMatch = [regex]::Match($content, '(?m)^\s*Name\s+"(?<ref>\{[0-9A-Fa-f]+\}[^\"]+)"')
    if (-not $nameMatch.Success) {
        throw "Failed to parse Name resource reference in meta file: $MetaPath"
    }

    return $nameMatch.Groups['ref'].Value
}

function Set-PrefabImageReference {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrefabPath,
        [Parameter(Mandatory = $true)]
        [string]$ResourceReference,
        [switch]$DryRun
    )

    $lineBuffer = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -Path $PrefabPath) {
        $lineBuffer.Add($line)
    }

    $uiInfoStart = -1
    for ($i = 0; $i -lt $lineBuffer.Count; $i++) {
        if ($lineBuffer[$i] -match '\bm_UIInfo\s+\w+\s+"[^\"]+"\s*\{') {
            $uiInfoStart = $i
            break
        }
    }

    if ($uiInfoStart -lt 0) {
        return "no-uiinfo"
    }

    $depth = 0
    $uiInfoEnd = -1
    for ($i = $uiInfoStart; $i -lt $lineBuffer.Count; $i++) {
        $depth += Get-BraceDelta -Line $lineBuffer[$i]
        if ($depth -eq 0 -and $i -gt $uiInfoStart) {
            $uiInfoEnd = $i
            break
        }
    }

    if ($uiInfoEnd -lt 0) {
        return "malformed-uiinfo"
    }

    $imageLineIndex = -1
    for ($i = $uiInfoStart + 1; $i -lt $uiInfoEnd; $i++) {
        if ($lineBuffer[$i] -match '^\s*m_Image\s+"[^\"]*"\s*$') {
            $imageLineIndex = $i
            break
        }
    }

    if ($imageLineIndex -ge 0) {
        $indent = Get-LeadingWhitespace -Text $lineBuffer[$imageLineIndex]
        $newLine = $indent + 'm_Image "' + $ResourceReference + '"'

        if ($lineBuffer[$imageLineIndex] -eq $newLine) {
            return "unchanged"
        }

        if (-not $DryRun) {
            $lineBuffer[$imageLineIndex] = $newLine
            Set-Content -Path $PrefabPath -Value $lineBuffer
        }

        return "updated"
    }

    $innerIndent = $null
    for ($i = $uiInfoStart + 1; $i -lt $uiInfoEnd; $i++) {
        $trimmed = $lineBuffer[$i].Trim()
        if ($trimmed.Length -eq 0 -or $trimmed -eq "}") {
            continue
        }

        $innerIndent = Get-LeadingWhitespace -Text $lineBuffer[$i]
        break
    }

    if ($null -eq $innerIndent) {
        $innerIndent = (Get-LeadingWhitespace -Text $lineBuffer[$uiInfoStart]) + " "
    }

    $insertLine = $innerIndent + 'm_Image "' + $ResourceReference + '"'

    if (-not $DryRun) {
        $lineBuffer.Insert($uiInfoEnd, $insertLine)
        Set-Content -Path $PrefabPath -Value $lineBuffer
    }

    return "inserted"
}

function Update-PrefabsFromMeta {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrefabsRootPath,
        [Parameter(Mandatory = $true)]
        [string]$MetaRootPath,
        [Parameter(Mandatory = $true)]
        [string]$Kind,
        [Parameter(Mandatory = $true)]
        [string]$Suffix,
        [switch]$DryRun
    )

    $result = [ordered]@{
        Kind = $Kind
        Total = 0
        Updated = 0
        Inserted = 0
        Unchanged = 0
        MissingMeta = 0
        MissingUIInfo = 0
        Malformed = 0
    }

    if (-not (Test-Path -Path $PrefabsRootPath -PathType Container)) {
        Write-Warning "$Kind prefab directory not found: $PrefabsRootPath"
        return [PSCustomObject]$result
    }

    $prefabFiles = @(Get-ChildItem -Path $PrefabsRootPath -Recurse -File -Filter "*.et" | Sort-Object FullName)
    foreach ($prefabFile in $prefabFiles) {
        $result.Total++

        $relativeDirectory = Get-NormalizedRelativePath -BasePath $PrefabsRootPath -TargetPath $prefabFile.DirectoryName
        $metaDirectory = $MetaRootPath
        if (-not [string]::IsNullOrEmpty($relativeDirectory)) {
            $metaDirectory = Join-Path $MetaRootPath $relativeDirectory
        }

        $metaPath = Join-Path $metaDirectory ($prefabFile.BaseName + $Suffix + ".edds.meta")
        $resourceReference = Get-ResourceReferenceFromMeta -MetaPath $metaPath
        if ($null -eq $resourceReference) {
            $result.MissingMeta++
            Write-Warning "Missing meta for $Kind prefab: $($prefabFile.FullName) (expected $metaPath)"
            continue
        }

        $status = Set-PrefabImageReference -PrefabPath $prefabFile.FullName -ResourceReference $resourceReference -DryRun:$DryRun
        switch ($status) {
            "updated" {
                $result.Updated++
                Write-Host "UPDATED  [$Kind] $($prefabFile.FullName)"
            }
            "inserted" {
                $result.Inserted++
                Write-Host "INSERTED [$Kind] $($prefabFile.FullName)"
            }
            "unchanged" {
                $result.Unchanged++
            }
            "no-uiinfo" {
                $result.MissingUIInfo++
                Write-Warning "No m_UIInfo block found in $Kind prefab: $($prefabFile.FullName)"
            }
            "malformed-uiinfo" {
                $result.Malformed++
                Write-Warning "Malformed m_UIInfo block in $Kind prefab: $($prefabFile.FullName)"
            }
            default {
                throw "Unexpected update status '$status' for prefab: $($prefabFile.FullName)"
            }
        }
    }

    return [PSCustomObject]$result
}

$charactersPrefabsPath = Resolve-RepoPath -Path $CharactersPrefabsDirectory
$groupsPrefabsPath = Resolve-RepoPath -Path $GroupsPrefabsDirectory
$charactersMetaPath = Resolve-RepoPath -Path $CharactersMetaDirectory
$groupsMetaPath = Resolve-RepoPath -Path $GroupsMetaDirectory

if ($DryRun) {
    Write-Host "Dry-run mode enabled. No prefab files will be modified."
}

Write-Host "Using meta suffix: $NameSuffix"

$characterResult = Update-PrefabsFromMeta -PrefabsRootPath $charactersPrefabsPath -MetaRootPath $charactersMetaPath -Kind "Characters" -Suffix $NameSuffix -DryRun:$DryRun
$groupResult = Update-PrefabsFromMeta -PrefabsRootPath $groupsPrefabsPath -MetaRootPath $groupsMetaPath -Kind "Groups" -Suffix $NameSuffix -DryRun:$DryRun

$allResults = @($characterResult, $groupResult)

foreach ($summary in $allResults) {
    Write-Host ""
    Write-Host "$($summary.Kind) summary:"
    Write-Host "  Total:       $($summary.Total)"
    Write-Host "  Updated:     $($summary.Updated)"
    Write-Host "  Inserted:    $($summary.Inserted)"
    Write-Host "  Unchanged:   $($summary.Unchanged)"
    Write-Host "  MissingMeta: $($summary.MissingMeta)"
    Write-Host "  MissingUI:   $($summary.MissingUIInfo)"
    Write-Host "  Malformed:   $($summary.Malformed)"
}

$allMissingMeta = ($allResults | Measure-Object -Property MissingMeta -Sum).Sum
$allMissingUi = ($allResults | Measure-Object -Property MissingUIInfo -Sum).Sum
$allMalformed = ($allResults | Measure-Object -Property Malformed -Sum).Sum

if (($allMissingMeta + $allMissingUi + $allMalformed) -gt 0) {
    Write-Warning "Completed with warnings. See summary above."
}
else {
    Write-Host ""
    if ($DryRun) {
        Write-Host "Dry-run completed successfully."
    }
    else {
        Write-Host "Linking completed successfully."
    }
}
