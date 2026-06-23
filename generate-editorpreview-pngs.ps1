[CmdletBinding()]
param(
    [string]$CharactersPrefabsDirectory = "Prefabs/Characters/Factions",
    [string]$GroupsPrefabsDirectory = "Prefabs/Groups",
    [string]$OutputRootDirectory = "UI/Textures/EditorPreviews",
    [string]$NameSuffix = "_BCR",
    [string]$SourcePngPath = "",
    [ValidateRange(1, 8192)]
    [int]$Width = 400,
    [ValidateRange(1, 8192)]
    [int]$Height = 300,
    [ValidateRange(0, 255)]
    [int]$Gray = 128,
    [switch]$CleanOutput
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

function New-GrayPngBytes {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ImageWidth,
        [Parameter(Mandatory = $true)]
        [int]$ImageHeight,
        [Parameter(Mandatory = $true)]
        [int]$GrayValue
    )

    try {
        Add-Type -AssemblyName System.Drawing | Out-Null
    }
    catch {
        throw "Failed to load System.Drawing. Use -SourcePngPath to provide an existing PNG if System.Drawing is unavailable."
    }

    $bitmap = $null
    $graphics = $null
    $stream = $null

    try {
        $bitmap = New-Object System.Drawing.Bitmap($ImageWidth, $ImageHeight)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $grayColor = [System.Drawing.Color]::FromArgb(255, $GrayValue, $GrayValue, $GrayValue)
        $graphics.Clear($grayColor)

        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    }
    finally {
        if ($null -ne $graphics) {
            $graphics.Dispose()
        }
        if ($null -ne $bitmap) {
            $bitmap.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-SourcePngBytes {
    param(
        [string]$ExplicitSourcePath,
        [Parameter(Mandatory = $true)]
        [int]$ImageWidth,
        [Parameter(Mandatory = $true)]
        [int]$ImageHeight,
        [Parameter(Mandatory = $true)]
        [int]$GrayValue,
        [ref]$SourceDescription
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitSourcePath)) {
        $resolvedPath = Resolve-RepoPath -Path $ExplicitSourcePath
        if (-not (Test-Path -Path $resolvedPath -PathType Leaf)) {
            throw "Provided source PNG does not exist: $resolvedPath"
        }

        if ([System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant() -ne ".png") {
            throw "Provided source is not a .png file: $resolvedPath"
        }

        $bytes = [System.IO.File]::ReadAllBytes($resolvedPath)
        if ($bytes.Length -eq 0) {
            throw "Provided source PNG is empty: $resolvedPath"
        }

        $SourceDescription.Value = "Using source PNG: $resolvedPath"
        return $bytes
    }

    $SourceDescription.Value = "Using generated gray PNG (${ImageWidth}x${ImageHeight}, gray=$GrayValue)"
    return (New-GrayPngBytes -ImageWidth $ImageWidth -ImageHeight $ImageHeight -GrayValue $GrayValue)
}

function Generate-PreviewFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrefabsRootPath,
        [Parameter(Mandatory = $true)]
        [string]$OutputRootPath,
        [Parameter(Mandatory = $true)]
        [byte[]]$SourcePngBytes,
        [Parameter(Mandatory = $true)]
        [string]$Suffix
    )

    if (-not (Test-Path -Path $PrefabsRootPath -PathType Container)) {
        Write-Warning "Prefab directory does not exist: $PrefabsRootPath"
        return 0
    }

    $prefabFiles = @(Get-ChildItem -Path $PrefabsRootPath -Recurse -File -Filter "*.et" | Sort-Object FullName)
    if ($prefabFiles.Count -eq 0) {
        return 0
    }

    $generatedCount = 0

    foreach ($prefabFile in $prefabFiles) {
        $relativeDirectory = Get-NormalizedRelativePath -BasePath $PrefabsRootPath -TargetPath $prefabFile.DirectoryName

        $targetDirectory = $OutputRootPath
        if (-not [string]::IsNullOrEmpty($relativeDirectory)) {
            $targetDirectory = Join-Path $OutputRootPath $relativeDirectory
        }

        if (-not (Test-Path -Path $targetDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        }

        $baseName = $prefabFile.BaseName
        $targetPngPath = Join-Path $targetDirectory ($baseName + $Suffix + ".png")
        [System.IO.File]::WriteAllBytes($targetPngPath, $SourcePngBytes)

        foreach ($stalePath in @(
            "$targetPngPath.meta",
            (Join-Path $targetDirectory ($baseName + ".png")),
            (Join-Path $targetDirectory ($baseName + ".png.meta")),
            (Join-Path $targetDirectory ($baseName + ".edds")),
            (Join-Path $targetDirectory ($baseName + ".edds.meta"))
        )) {
            if (Test-Path -Path $stalePath -PathType Leaf) {
                Remove-Item -Path $stalePath -Force
            }
        }

        $generatedCount++
    }

    return $generatedCount
}

$charactersPrefabsPath = Resolve-RepoPath -Path $CharactersPrefabsDirectory
$groupsPrefabsPath = Resolve-RepoPath -Path $GroupsPrefabsDirectory
$outputRootPath = Resolve-RepoPath -Path $OutputRootDirectory

$sourceDescription = ""
$sourcePngBytes = Get-SourcePngBytes -ExplicitSourcePath $SourcePngPath -ImageWidth $Width -ImageHeight $Height -GrayValue $Gray -SourceDescription ([ref]$sourceDescription)
Write-Host $sourceDescription

$charactersOutputPath = Join-Path $outputRootPath "Characters/Factions"
$groupsOutputPath = Join-Path $outputRootPath "Groups"

if ($CleanOutput) {
    foreach ($pathToClean in @($charactersOutputPath, $groupsOutputPath)) {
        if (Test-Path -Path $pathToClean -PathType Container) {
            Remove-Item -Path $pathToClean -Recurse -Force
            Write-Host "Cleaned output: $pathToClean"
        }
    }
}

if (-not (Test-Path -Path $outputRootPath -PathType Container)) {
    New-Item -ItemType Directory -Path $outputRootPath -Force | Out-Null
}

$charactersGenerated = Generate-PreviewFiles -PrefabsRootPath $charactersPrefabsPath -OutputRootPath $charactersOutputPath -SourcePngBytes $sourcePngBytes -Suffix $NameSuffix
$groupsGenerated = Generate-PreviewFiles -PrefabsRootPath $groupsPrefabsPath -OutputRootPath $groupsOutputPath -SourcePngBytes $sourcePngBytes -Suffix $NameSuffix

Write-Host "Generated $charactersGenerated character preview image(s)."
Write-Host "Generated $groupsGenerated group preview image(s)."
Write-Host "Generated $($charactersGenerated + $groupsGenerated) total .png file(s)."