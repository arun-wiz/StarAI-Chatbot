<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Trivy Image Scan</title>
<link rel="stylesheet" href="trivy-report.css"/>
</head>
<body>
<div class="wrap">
  <header>
    <div class="title">Trivy Image Scan <span class="muted">— vulnerabilities & secrets (CSP-safe)</span></div>
    <nav>
      <a href="#vulns">Vulnerabilities</a>
      <a href="#secrets">Secrets</a>
    </nav>
  </header>

  <!-- Global hidden checkboxes for CSS-only filters -->
  <input id="sevCritical" type="checkbox" checked hidden>
  <input id="sevHigh"     type="checkbox" checked hidden>
  <input id="sevMedium"   type="checkbox" checked hidden>
  <input id="sevLow"      type="checkbox" checked hidden>
  <input id="sevUnknown"  type="checkbox" checked hidden>
  <input id="showSecrets" type="checkbox" hidden>

  <div class="card">
    <div class="controls checkboxes">
      <div class="pill">
        <strong>Severity:</strong>
        <label for="sevCritical">Critical</label>
        <label for="sevHigh">High</label>
        <label for="sevMedium">Medium</label>
        <label for="sevLow">Low</label>
        <label for="sevUnknown">Unknown</label>
      </div>
      <div class="pill">
        <label for="showSecrets">Show secret matches</label>
      </div>
    </div>
  </div>

  <!-- Vulnerabilities -->
  <section id="vulns" class="card">
    <h2>Vulnerabilities</h2>
    <table data-kind="vuln">
      <thead>
        <tr>
          <th>Severity</th><th>CVE / ID</th><th>Package</th><th>Installed</th><th>Fixed</th><th>Title</th><th>Target</th><th>Refs</th>
        </tr>
      </thead>
      <tbody>
      {{- range $r := . -}}
        {{- if $r.Vulnerabilities -}}
          {{- range $v := $r.Vulnerabilities -}}
            <tr data-sev="{{ $v.Severity }}">
              <td><span class="badge sev-{{ $v.Severity }}">{{ $v.Severity }}</span></td>
              <td><code>{{ $v.VulnerabilityID }}</code></td>
              <td>{{ $v.PkgName }}</td>
              <td>{{ $v.InstalledVersion }}</td>
              <td>{{ if $v.FixedVersion }}{{ $v.FixedVersion }}{{ else }}-{{ end }}</td>
              <td>{{ if $v.Title }}{{ $v.Title }}{{ else }}-{{ end }}</td>
              <td>{{ $r.Target }}</td>
              <td>{{- if $v.PrimaryURL -}}<a href="{{ $v.PrimaryURL }}" target="_blank" rel="noopener noreferrer">link</a>{{- else -}}-{{- end -}}</td>
            </tr>
          {{- end -}}
        {{- end -}}
      {{- end -}}
      </tbody>
    </table>
    <div class="empty-note">No vulnerabilities (with current filters).</div>
  </section>

  <!-- Secrets -->
  <section id="secrets" class="card">
    <h2>Secrets</h2>
    <table data-kind="secret">
      <thead>
        <tr>
          <th>Severity</th><th>Rule</th><th>Title</th><th>Match</th><th>Layer/File</th><th>Lines</th>
        </tr>
      </thead>
      <tbody>
      {{- range $r := . -}}
        {{- if $r.Secrets -}}
          {{- range $s := $r.Secrets -}}
            <tr data-sev="{{ $s.Severity }}">
              <td><span class="badge sev-{{ $s.Severity }}">{{ $s.Severity }}</span></td>
              <td><code>{{ $s.RuleID }}</code></td>
              <td>{{ if $s.Title }}{{ $s.Title }}{{ else }}-{{ end }}</td>
              <td>
                <span class="secret-masked">•••••••</span>
                <span class="secret-plain">{{ $s.Match }}</span>
              </td>
              <td>{{ $r.Target }}</td>
              <td>
                {{- if and $s.StartLine $s.EndLine -}}
                  {{ $s.StartLine }}–{{ $s.EndLine }}
                {{- else -}}-{{- end -}}
              </td>
            </tr>
          {{- end -}}
        {{- end -}}
      {{- end -}}
      </tbody>
    </table>
    <div class="empty-note">No secrets (with current filters).</div>
  </section>

  <div class="foot">
    CSP-safe view: no JavaScript, external CSS only. Use the labels above to toggle severity visibility and reveal secret matches.
  </div>
</div>
</body>
</html>
