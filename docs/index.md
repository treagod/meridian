---
layout: false
title: Meridian - Deploy containers anywhere
description: A native CLI that ships your containers to any Linux box - Podman Quadlets for supervision, kamal-proxy for zero-downtime cutovers, and no registry required.
---

<script setup>
import './.vitepress/theme/landing.css'
import { onMounted, onBeforeUnmount, ref } from 'vue'

const installCmd = 'curl -fsSL meridian-deploy.dev/install.sh | sh'
const copyLabel = ref('COPY')

function copyInstall() {
  if (typeof navigator === 'undefined' || !navigator.clipboard) return
  navigator.clipboard.writeText(installCmd).then(() => {
    copyLabel.value = 'COPIED'
    setTimeout(() => { copyLabel.value = 'COPY' }, 1400)
  }).catch(() => {
    copyLabel.value = 'FAIL'
    setTimeout(() => { copyLabel.value = 'COPY' }, 1400)
  })
}

onMounted(() => {
  document.documentElement.classList.add('landing-page-active')
  document.body.classList.add('landing-page-active')
})

onBeforeUnmount(() => {
  document.documentElement.classList.remove('landing-page-active')
  document.body.classList.remove('landing-page-active')
})
</script>

<div class="landing-root">

<nav class="top">
  <div class="container">
    <a href="#" class="brand">
      <img class="brand-mark" src="/meridian.png" alt="" aria-hidden="true" />
      Meridian
    </a>
    <div class="links">
      <a href="#why">Why</a>
      <a href="#features">Features</a>
      <a href="#compare">Compare</a>
      <a href="#faq">FAQ</a>
      <a href="https://github.com/treagod/meridian" target="_blank" rel="noreferrer">GitHub</a>
    </div>
    <a href="/guide/" class="cta">Read the Docs →</a>
  </div>
</nav>

<section class="hero">
  <div class="container">
    <div>
      <div class="eyebrow fade-in">Meridian · Podman native</div>
      <h1 class="display fade-in">
        Deploy containers <em>anywhere.</em>
      </h1>
      <p class="lede fade-in">
        A native CLI that ships your containers to any Linux box -
        <strong>Podman Quadlets</strong> for supervision, <strong>kamal-proxy</strong>
        for zero-downtime cutovers, and no registry required.
      </p>
      <div class="install fade-in">
        <span class="install-corner tl"></span>
        <span class="install-corner tr"></span>
        <span class="install-corner bl"></span>
        <span class="install-corner br"></span>
        <span class="prompt">$</span>
        <code>{{ installCmd }}</code>
        <button @click="copyInstall">{{ copyLabel }}</button>
      </div>
      <div class="cta-row fade-in">
        <a href="/guide/quickstart" class="btn btn-primary">Read the Quickstart →</a>
        <a href="https://github.com/treagod/meridian" class="btn btn-ghost" target="_blank" rel="noreferrer"><svg class="lucide lucide-star" xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z" /></svg>Star on GitHub</a>
      </div>
    </div>
    <div class="terminal fade-in" aria-label="Deploy demo">
      <div class="terminal-head">
        <div class="terminal-dots"><span></span><span></span><span></span></div>
        <span>~/my-app - meridian deploy</span>
      </div>
      <div class="terminal-body"><span class="line"><span class="prompt">$</span> <span class="cmd">meridian deploy</span></span><span class="line"><span class="orch">Deploying my-app to 1 web host</span></span><span class="line"><span class="host">[prod-01]</span> Streaming image my-app:abcd1234</span><span class="line"><span class="host">[prod-01]</span> Transferred 12.4 MB in 3.1s</span><span class="line"><span class="host">[prod-01]</span> Uploading service Quadlet</span><span class="line"><span class="host">[prod-01]</span> Reloading user systemd</span><span class="line"><span class="host">[prod-01]</span> Starting service my-app-green.service</span><span class="line"><span class="host">[prod-01]</span> Checking health for my-app-green</span><span class="line"><span class="host">[prod-01]</span> Switching proxy traffic to my-app-green</span><span class="line"><span class="host">[prod-01]</span> Stopping service my-app-blue.service</span><span class="line"><span class="host">[prod-01]</span> Recording active color green</span><span class="line"><span class="host">[prod-01]</span> Deploy completed</span><span class="line"><span class="orch">Deploy completed</span><span class="cursor"></span></span></div>
    </div>
  </div>
</section>

<section id="install">
  <div class="container">
    <div class="section-header">
      <span class="section-eyebrow">The flow</span>
      <h2 class="section-title">Three commands from <em>repo to running.</em></h2>
      <p class="section-sub">
        No Kubernetes. No Docker Swarm. No CI/CD rebuild loop. Meridian is an imperative CLI that does what you tell it, when you tell it.
      </p>
    </div>
    <div class="steps-grid">
      <div class="step">
        <span class="step-num">I · Initialize</span>
        <h3>Detect &amp; configure</h3>
        <p>
          Meridian scans your project, picks up Marten, Rails, Elixir, Node or Go, and writes a working <code class="inline-code">deploy.yml</code> you can read and edit.
        </p>
        <span class="step-cmd">$ meridian init</span>
      </div>
      <div class="step">
        <span class="step-num">II · Deploy</span>
        <h3>Ship, run, supervise</h3>
        <p>
          Send the image you've already built to each host - registry pull, SSH stream, or rsync'd OCI layout. systemd takes over through a Quadlet unit. No Docker daemon on the target.
        </p>
        <span class="step-cmd">$ meridian deploy</span>
      </div>
      <div class="step">
        <span class="step-num">III · Cut over</span>
        <h3>Zero-downtime release</h3>
        <p>
          <code class="inline-code">kamal-proxy</code> routes traffic from the old container to the new one only after health checks pass. Rollback is a single command.
        </p>
        <span class="step-cmd">$ meridian rollback</span>
      </div>
    </div>
  </div>
</section>

<div class="container">
  <div class="meridian-divider">
    <svg viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="8" cy="8" r="6" stroke="currentColor" stroke-width="1" fill="none"/>
      <path d="M8 2 L8 14 M2 8 L14 8" stroke="currentColor" stroke-width="0.8"/>
      <circle cx="8" cy="8" r="1.2" fill="currentColor"/>
    </svg>
  </div>
</div>

<section class="why" id="why">
  <div class="container">
    <div class="section-header" style="max-width: 820px;">
      <span class="section-eyebrow">The position</span>
      <h2 class="section-title">Kubernetes is a platform. <em>Meridian is a tool.</em></h2>
    </div>
    <div class="why-grid">
      <div class="why-prose">
        <p>
          Most deploy stacks ask you to adopt a <strong>worldview</strong>. Declarative reconciliation loops, control planes, custom resource definitions - a full philosophy for managing fleets you do not have.
        </p>
        <p>
          Meridian is smaller on purpose. It does one job: take a container from your laptop and run it on a Linux server you rent, own, or colocate. When you push again, it cuts over cleanly. When something breaks, you read a systemd log.
        </p>
        <p>
          No orchestrator. No registry tax. No daemon. <strong>A tool, not a platform.</strong>
        </p>
      </div>
      <div class="why-aside">
        <h4>· Why Podman</h4>
        <p>Rootless-first is the right default in 2026. Quadlets let systemd supervise containers natively - the same system that already supervises your SSH daemon and cron jobs.</p>
        <h4>· Why registries are optional</h4>
        <p>Use one if you have one. When you'd rather skip it, Meridian ships the image straight over SSH - piped with zstd, or rsync'd as an OCI layout so later deploys send only what changed.</p>
        <h4>· Why framework-aware</h4>
        <p><code class="inline-code">meridian init</code> recognizes Marten, Rails, Elixir, Go, and Node - sets the right <code class="inline-code">*_ENV</code> default, reuses your health route where it can find one, and writes a <code class="inline-code">deploy.yml</code> you can edit on the first try.</p>
        <h4>· Why Crystal</h4>
        <p>One compiled executable. No Ruby, no Python, no Node runtime on the server. Official Linux release builds can ship as a single file; local Crystal builds may still link shared libraries.</p>
      </div>
    </div>
  </div>
</section>

<section id="features">
  <div class="container">
    <div class="section-header">
      <span class="section-eyebrow">Feature set</span>
      <h2 class="section-title">Everything the job needs. <em>Nothing it doesn't.</em></h2>
      <p class="section-sub">
        Meridian ships a small, sharp feature surface aimed at the 80% deploy path - the remaining 20% is where you'd want Kubernetes anyway.
      </p>
    </div>
    <div class="features-grid">
      <div class="feature">
        <div class="feature-icon">
          <svg class="lucide lucide-panels-top-left" xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="2" /><path d="M3 9h18" /><path d="M9 21V9" /></svg>
        </div>
        <h3>Podman Quadlets</h3>
        <p>Your containers run under systemd. Restart policies, journald logs, and dependency ordering you already understand.</p>
      </div>
      <div class="feature">
        <div class="feature-icon">
          <svg class="lucide lucide-expand" xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 15 6 6" /><path d="m15 9 6-6" /><path d="M21 16v5h-5" /><path d="M21 8V3h-5" /><path d="M3 16v5h5" /><path d="m3 21 6-6" /><path d="M3 8V3h5" /><path d="M9 9 3 3" /></svg>
        </div>
        <h3>Blue / Green via kamal-proxy</h3>
        <p>Zero-downtime cutovers with health checks. If the new container fails, traffic stays on the old one. No drama.</p>
      </div>
      <div class="feature">
        <div class="feature-icon">
          <svg class="lucide lucide-arrow-right-left" xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m16 3 4 4-4 4" /><path d="M20 7H4" /><path d="m8 21-4-4 4-4" /><path d="M4 17h16" /></svg>
        </div>
        <h3>Skip the registry</h3>
        <p>Keep pulling from a registry, or flip <code class="inline-code">transfer.mode</code> to <code class="inline-code">stream</code> or <code class="inline-code">incremental</code> and Meridian ships images over your existing SSH connection - no Docker Hub bill, no ECR setup, no CI upload step.</p>
      </div>
      <div class="feature">
        <div class="feature-icon">
          <svg class="lucide lucide-layers" xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83z" /><path d="M2 12a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 12" /><path d="M2 17a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 17" /></svg>
        </div>
        <h3>Framework Auto-Detection</h3>
        <p><code class="inline-code">meridian init</code> recognizes Marten, Rails, Elixir, Node, and Go and writes a working config you can actually read.</p>
      </div>
      <div class="feature">
        <div class="feature-icon">
          <svg class="lucide lucide-key-round" xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z" /><circle cx="16.5" cy="7.5" r=".5" fill="currentColor" /></svg>
        </div>
        <h3>Podman Secrets, not .env files</h3>
        <p><code class="inline-code">meridian secret set</code> manages encrypted secrets on every host. Names listed under <code class="inline-code">env.secret</code> reach the container through the Quadlet's <code class="inline-code">Secret=</code> directive - nothing plaintext on disk, nothing baked into the image.</p>
      </div>
      <div class="feature">
        <div class="feature-icon">
          <svg class="lucide lucide-webhook" xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 16.98h-5.99c-1.1 0-1.95.94-2.48 1.9A4 4 0 0 1 2 17c.01-.7.2-1.4.57-2" /><path d="m6 17 3.13-5.78c.53-.97.1-2.18-.5-3.1a4 4 0 1 1 6.89-4.06" /><path d="m12 6 3.13 5.73C15.66 12.7 16.9 13 18 13a4 4 0 0 1 0 8" /></svg>
        </div>
        <h3>Remote deploy hooks</h3>
        <p>Eight phases from <code class="inline-code">before_transfer</code> to <code class="inline-code">after_deploy</code> run arbitrary commands on each host. Migrations, cache warms, smoke tests - declare them in <code class="inline-code">deploy.yml</code> and Meridian fires them in order.</p>
      </div>
    </div>
  </div>
</section>

<section id="compare">
  <div class="container">
    <div class="section-header">
      <span class="section-eyebrow">Honest comparison</span>
      <h2 class="section-title">Where Meridian <em>actually fits.</em></h2>
      <p class="section-sub">
        If you're happy with Kamal or Dokku, you should probably stay there - both are mature. Meridian makes different trade-offs. Here's what you're buying into:
      </p>
    </div>
    <div class="compare-wrap">
      <table class="compare">
        <thead>
          <tr>
            <th></th>
            <th class="own">Meridian</th>
            <th>Kamal 2</th>
            <th>Dokku</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Runtime</td>
            <td class="own">Podman + systemd</td>
            <td>Docker daemon</td>
            <td>Docker daemon</td>
          </tr>
          <tr>
            <td>Supervision</td>
            <td class="own">Quadlets (systemd)</td>
            <td>Docker restart</td>
            <td>Docker restart</td>
          </tr>
          <tr>
            <td>Image transfer</td>
            <td class="own">Direct over SSH</td>
            <td>Registry required</td>
            <td>Local build on host</td>
          </tr>
          <tr>
            <td>Zero-downtime</td>
            <td class="own">kamal-proxy</td>
            <td>kamal-proxy</td>
            <td>nginx / Traefik</td>
          </tr>
          <tr>
            <td>Rootless by default</td>
            <td class="own">Yes</td>
            <td>No</td>
            <td>No</td>
          </tr>
          <tr>
            <td>Install</td>
            <td class="own">Native executable</td>
            <td>Ruby gem</td>
            <td>Bash bootstrap + apt</td>
          </tr>
          <tr>
            <td>Config</td>
            <td class="own">YAML</td>
            <td>YAML</td>
            <td>Imperative CLI</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</section>

<section style="padding: 0;">
  <div class="container">
    <div class="stats-row">
      <div>
        <div class="stat-label">License</div>
        <div class="stat-value">MIT</div>
      </div>
      <div>
        <div class="stat-label">Runtime</div>
        <div class="stat-value"><em>Podman</em> + <em>systemd</em></div>
      </div>
      <div>
        <div class="stat-label">Written in</div>
        <div class="stat-value"><em>Crystal</em></div>
      </div>
    </div>
  </div>
</section>

<section id="faq">
  <div class="container faq-wrap">
    <div class="section-header" style="text-align: center; margin-left: auto; margin-right: auto;">
      <span class="section-eyebrow">Questions</span>
      <h2 class="section-title">The honest answers.</h2>
    </div>
    <details class="faq-item">
      <summary>Does this replace Kamal?</summary>
      <div class="answer">
        No - and it's not trying to. Kamal is mature, Docker-centric, and Ruby-ecosystem-friendly. Meridian is for teams that want Podman + systemd semantics, a native executable, and registry-free transfers. If your team already runs Kamal happily, there's no reason to switch.
      </div>
    </details>
    <details class="faq-item">
      <summary>Is it really a single-file binary?</summary>
      <div class="answer">
        For the official Linux release builds, yes: Crystal supports static linking, and Meridian builds cleanly as a static Alpine/musl binary. But that depends on how you build it. A default local build on macOS is still one executable file, but it links against shared libraries such as OpenSSL, libyaml, PCRE2, and Boehm GC.
      </div>
    </details>
    <details class="faq-item">
      <summary>Why Podman over Docker?</summary>
      <div class="answer">
        <p>Three reasons:</p>
        <ul>
          <li>Rootless-first is the correct default in 2026.</li>
          <li>Quadlets integrate containers into <code>systemd</code> as first-class units, including restart policies, dependency ordering, and journald logging.</li>
          <li>There is no long-running daemon to babysit or restart.</li>
        </ul>
      </div>
    </details>
    <details class="faq-item">
      <summary>How does SSH image transfer work?</summary>
      <div class="answer">
        Two registry-free paths. <code>transfer.mode: stream</code> pipes <code>podman save | zstd</code> over SSH to <code>podman load</code> on the host - simple, no extra infrastructure. <code>transfer.mode: incremental</code> syncs an OCI layout via rsync, so repeat deploys typically send only the bytes that changed. If you already have SSH to the server, you have everything Meridian needs.
      </div>
    </details>
    <details class="faq-item">
      <summary>Is it production-ready?</summary>
      <div class="answer">
        Meridian is in early development and currently used on a handful of production workloads, but the API may still change. It ships with test coverage on every increment. If you need SOC2 and an on-call vendor, use Render or Fly.io. If you can read systemd logs, you'll be fine.
      </div>
    </details>
    <details class="faq-item">
      <summary>Can I bring my own proxy?</summary>
      <div class="answer">
        kamal-proxy is the default because blue/green is the whole point. But Meridian writes standard Quadlet units, so if you want Caddy or Traefik in front of them, nothing is stopping you.
      </div>
    </details>
    <details class="faq-item">
      <summary>What about databases, Redis, background jobs?</summary>
      <div class="answer">
        Accessory services are first-class - define them in <code>deploy.yml</code> and they deploy alongside your app. Meridian treats them as Quadlet units too, which means systemd handles their lifecycle consistently with everything else.
      </div>
    </details>
  </div>
</section>

<section class="closing">
  <div class="container">
    <h2>Set your bearings. <em>Deploy.</em></h2>
    <p>Meridian is open source and MIT-licensed. Try it on a staging box this weekend - the install is a single command.</p>
    <div class="cta-row" style="justify-content: center;">
      <a href="/guide/quickstart" class="btn btn-primary">Read the Quickstart →</a>
      <a href="https://github.com/treagod/meridian" class="btn btn-ghost" target="_blank" rel="noreferrer"><svg class="lucide lucide-star" xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z" /></svg>Star on GitHub</a>
    </div>
  </div>
</section>

<footer>
  <div class="container">
    <div style="display:flex; align-items:center; gap:10px;">
      <img class="brand-mark brand-mark-sm" src="/meridian.png" alt="" aria-hidden="true" />
      <span style="font-family:var(--serif); color:var(--cream); font-weight:600;">Meridian</span>
    </div>
    <div class="links-row">
      <a href="https://github.com/treagod/meridian" target="_blank" rel="noreferrer">GitHub</a>
      <a href="/guide/">Docs</a>
      <a href="#">Discord</a>
      <a href="#">Changelog</a>
    </div>
    <div class="latitude">48.6° N · 9.2° E</div>
  </div>
</footer>

</div>
