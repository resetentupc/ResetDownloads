<#
.SYNOPSIS
    Regenera la lista de reserva incrustada en Gestor-ResetEntuPC.ps1.

.DESCRIPTION
    Lee los releases públicos de github.com/resetentupc/ResetDownloads (solo lectura), se queda
    con los paquetes .nupkg válidos y reescribe el bloque entre los marcadores
    LISTA-RESERVA-INICIO y LISTA-RESERVA-FIN del gestor. Muestra qué modelos se añaden o se
    quitan respecto a la lista anterior y comprueba la sintaxis del archivo resultante: si
    hubiera errores, deja el archivo como estaba.

    - Si la lista de modelos no cambia, NO toca el archivo (así la fecha no genera cambios).
    - Si la lista nueva es mucho más corta que la anterior (posible respuesta incompleta de
      GitHub), se detiene sin cambiar nada. Se puede forzar con -Forzar.
    - Si existe la variable de entorno GITHUB_TOKEN (la GitHub Action la aporta sola), se usa
      solo para no chocar con el límite de consultas anónimas. No hace falta en local.

    Se ejecuta solo desde la GitHub Action "Actualizar lista de reserva del gestor" cada vez
    que se genera un .nupkg nuevo. También se puede lanzar a mano.

.PARAMETER Ruta
    Archivo del gestor a actualizar (por defecto, el que está junto a este script).

.PARAMETER Forzar
    Permite aceptar una lista mucho más corta que la anterior.

.PARAMETER WhatIf
    Solo muestra los cambios, sin escribir nada.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Ruta = (Join-Path $PSScriptRoot 'Gestor-ResetEntuPC.ps1'),
    [string]$Repo = 'resetentupc/ResetDownloads',
    [switch]$Forzar
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Mismos patrones que usa el gestor: lo que no encaje no entra en la lista.
$patronId  = '^(l|m|et-|wf-|xp-|sp-|cx-|sc-p|artisan-)\d{3,4}$'
$patronTag = '^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$'

if (-not (Test-Path -LiteralPath $Ruta)) { throw "No existe el archivo: $Ruta" }

# 1) Leer los releases (del más nuevo al más antiguo, igual que hace el gestor)
$cab = @{ 'User-Agent' = 'ResetEntuPC-ListaReserva'; 'Accept' = 'application/vnd.github+json' }
if ($env:GITHUB_TOKEN) { $cab['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
$releases = @()
foreach ($pg in 1..10) {
    $resp = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=100&page=$pg" -Headers $cab -TimeoutSec 30
    $lote = @($resp | ForEach-Object { $_ })
    if ($lote.Count -eq 0) { break }
    $releases += $lote
    if ($lote.Count -lt 100) { break }
}

$vistos = @{}
$filas = New-Object System.Collections.Generic.List[object]
$descartados = @()
foreach ($rel in $releases) {
    foreach ($a in @($rel.assets)) {
        if ($a.name -notlike '*.1.0.0.nupkg') { continue }
        $id = $a.name -replace '\.1\.0\.0\.nupkg$', ''
        $tag = [string]$rel.tag_name
        if ($id -cnotmatch $patronId -or $tag -notmatch $patronTag) { $descartados += "$($a.name) (etiqueta $tag)"; continue }
        if ($vistos.ContainsKey($id)) { continue }
        $vistos[$id] = $true
        $filas.Add([pscustomobject]@{ Id = $id; Tag = $tag })
    }
}
if ($filas.Count -eq 0) { throw 'GitHub no devolvió ningún paquete válido; no se cambia nada.' }
$ordenadas = @($filas | Sort-Object @{ Expression = { $_.Id -replace '\d+$', '' } }, @{ Expression = { [int]($_.Id -replace '^\D+', '') } })
$bloque = ($ordenadas | ForEach-Object { "$($_.Id)|$($_.Tag)" }) -join "`n"

# 2) Localizar el bloque dentro del gestor
$original = [IO.File]::ReadAllText($Ruta)
$crlf = $original.Contains("`r`n")
$texto = $original.Replace("`r`n", "`n")
$patron = "(?s)(# >>> LISTA-RESERVA-INICIO <<<\n)(.*?)(# >>> LISTA-RESERVA-FIN <<<)"
if ($texto -notmatch $patron) { throw 'No se encontraron los marcadores LISTA-RESERVA-INICIO / LISTA-RESERVA-FIN.' }

# Lista que había antes (id|etiqueta), para informar de diferencias y decidir si hay que escribir
$bloqueAntes = ''
if ($Matches[2] -match "(?s)@'\n(.*?)\n'@") { $bloqueAntes = $Matches[1] }
$antesLineas = @($bloqueAntes -split '\n' | Where-Object { $_ -match '\|' })
$antes = @($antesLineas | ForEach-Object { ($_ -split '\|')[0] })
$ahora = @($ordenadas | ForEach-Object { $_.Id })
$nuevos = @($ahora | Where-Object { $antes -notcontains $_ })
$quitados = @($antes | Where-Object { $ahora -notcontains $_ })

"Modelos en GitHub: $($ahora.Count)   (antes en el archivo: $($antes.Count))"
"Añadidos ($($nuevos.Count)): " + ($nuevos -join ', ')
"Quitados ($($quitados.Count)): " + ($quitados -join ', ')
if ($descartados.Count) { "Descartados por no cumplir el patrón ($($descartados.Count)): " + ($descartados -join '; ') }

# Sin cambios en la lista (ids y etiquetas): no se toca el archivo, ni siquiera la fecha.
if ($bloqueAntes.Trim() -ceq $bloque.Trim()) { 'La lista ya estaba al día. No se cambia nada.'; return }

# Protección: una lista mucho más corta suele ser una respuesta incompleta de GitHub.
if (-not $Forzar -and $antes.Count -ge 10 -and $ahora.Count -lt [math]::Floor($antes.Count * 0.7)) {
    throw "La lista nueva ($($ahora.Count)) es mucho más corta que la anterior ($($antes.Count)). No se cambia nada; usa -Forzar si es correcto."
}

$fecha = Get-Date -Format 'yyyy-MM-dd'
$nuevoCuerpo = "`$script:ListaReservaFecha = '$fecha'`n`$script:ListaReserva = @'`n$bloque`n'@`n"
$resultado = [regex]::Replace($texto, $patron, { param($m) $m.Groups[1].Value + $nuevoCuerpo + $m.Groups[3].Value })

# 3) Escribir (UTF-8 con BOM, con los mismos saltos de línea) y comprobar la sintaxis
if ($PSCmdlet.ShouldProcess($Ruta, "Reescribir la lista de reserva ($($ahora.Count) modelos, $fecha)")) {
    $final = if ($crlf) { $resultado.Replace("`n", "`r`n") } else { $resultado }
    [IO.File]::WriteAllText($Ruta, $final, (New-Object System.Text.UTF8Encoding($true)))
    $errores = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Ruta, [ref]$tokens, [ref]$errores)
    if ($errores.Count -gt 0) {
        [IO.File]::WriteAllText($Ruta, $original, (New-Object System.Text.UTF8Encoding($true)))
        throw "El archivo resultante tenía $($errores.Count) errores de sintaxis; se restauró el original."
    }
    "Lista de reserva actualizada: $($ahora.Count) modelos ($fecha). Sintaxis correcta."
}
