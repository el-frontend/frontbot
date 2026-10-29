import Image from "next/image";
import type { ReactNode } from "react";

// Always the newest GitHub Release, built by .github/workflows/release.yml.
const DOWNLOAD_URL = "https://github.com/el-frontend/frontbot/releases/latest/download/Frontbot.zip";
const VIDEO_URL = "https://fi2ff4bqbyqm9rxi.public.blob.vercel-storage.com/frontbot-presentation.mp4";

function Icon({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <svg
      aria-hidden="true"
      width="26"
      height="26"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
    >
      {children}
    </svg>
  );
}

function DownloadIcon() {
  return (
    <svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 3v12" />
      <path d="m7 10 5 5 5-5" />
      <path d="M5 21h14" />
    </svg>
  );
}

function Eyebrow({ children }: { children: ReactNode }) {
  return (
    <p className="m-0 font-mono text-[13px] uppercase tracking-[0.08em] text-accent">{children}</p>
  );
}

function SectionTitle({ children }: { children: ReactNode }) {
  return (
    <h2 className="m-0 text-[clamp(34px,4.5vw,52px)] font-extrabold leading-[1.08] tracking-[-0.03em]">
      {children}
    </h2>
  );
}

const features = [
  {
    title: "Chat with your agents",
    body: "Ask for posts, research or reminders the way you'd ask a teammate. Line up your next messages while an agent is still working.",
    icon: <path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z" />,
  },
  {
    title: "A guide for every brand",
    body: "Each brand gets its own voice, topics, audience and images. Agents read the guide before they write anything.",
    icon: (
      <>
        <path d="M4 4h10l6 6v10H4z" />
        <path d="M14 4v6h6" />
        <path d="M8 14h8" />
        <path d="M8 17h5" />
      </>
    ),
  },
  {
    title: "Posts and calendar",
    body: "Instagram and LinkedIn drafts show up in a weekly or monthly calendar. You review and approve each one.",
    icon: (
      <>
        <rect x="3" y="5" width="18" height="16" rx="2" />
        <path d="M3 10h18" />
        <path d="M8 3v4" />
        <path d="M16 3v4" />
      </>
    ),
  },
  {
    title: "Specialist agents",
    body: "Build your own Community Manager, Copywriter or Researcher, each with its own instructions, model and skills.",
    icon: (
      <>
        <circle cx="9" cy="8" r="3.5" />
        <path d="M2.5 20a6.5 6.5 0 0 1 13 0" />
        <circle cx="17.5" cy="9" r="2.5" />
        <path d="M16 14.2A5 5 0 0 1 21.5 19" />
      </>
    ),
  },
  {
    title: "Ideas and scheduled tasks",
    body: "Business ideas researched with sources and a score. Recurring tasks run every day, every week or every few minutes while Frontbot is open.",
    icon: (
      <>
        <path d="M9 18h6" />
        <path d="M10 21h4" />
        <path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2.1h5c0-.9.4-1.6 1-2.1A6 6 0 0 0 12 3z" />
      </>
    ),
  },
  {
    title: "Always at hand",
    body: (
      <>
        Press{" "}
        <kbd className="rounded-md border border-strong-edge px-1.5 font-mono text-[13px] text-text">
          ⌥⌘ Space
        </kbd>{" "}
        to open a panel from the notch, or dictate to your agents by voice.
      </>
    ),
    icon: (
      <>
        <rect x="3" y="7" width="18" height="12" rx="2" />
        <path d="M7 11h.01" />
        <path d="M11 11h.01" />
        <path d="M15 11h.01" />
        <path d="M7 15h10" />
      </>
    ),
  },
];

const steps = [
  {
    title: "Tell it about your brand",
    body: "Answer a short interview or import a PDF. Frontbot turns it into a brand guide that every agent reads.",
  },
  {
    title: "Review the drafts",
    body: "Ask for a week of posts. Drafts land in the calendar so you can edit, swap images and approve.",
  },
  {
    title: "Click Publish yourself",
    body: "Frontbot opens Instagram or LinkedIn in your browser with the text and images in place. The final click is yours.",
  },
];

const promises = [
  {
    title: "You make the final click",
    body: "Agents draft posts and get them ready. Publishing is always up to you.",
  },
  {
    title: "Everything stays on your Mac",
    body: "Brands, posts and memory are stored locally. Nothing goes to a Frontbot cloud.",
  },
  { title: "Spanish and English", body: "The app follows your Mac's language." },
];

const safety = [
  { title: "Only the folders you choose", body: "Agents ask before they write a file." },
  { title: "Only the sites you allow", body: "Network access is limited to sites on your allowlist." },
  { title: "Scripts in a sandbox", body: "Skill scripts run isolated, and only with your approval." },
  {
    title: "Memory you can see",
    body: "Every note an agent keeps about you is visible, and you can delete any of them.",
  },
];

const installSteps = [
  "Unzip Frontbot.zip and drag Frontbot to your Applications folder.",
  "Open Frontbot. When macOS says it can't verify the app, click Done.",
  "Go to System Settings → Privacy & Security, scroll down and click Open Anyway, then enter your Mac password.",
  "That's it. Frontbot opens normally from now on.",
];

const container = "mx-auto w-full max-w-[1200px] px-6";

export default function Home() {
  return (
    <div className="text-[17px] leading-[1.55]">
      <header className="border-b border-line">
        <nav aria-label="Main" className={`${container} flex flex-wrap items-center justify-between gap-4 py-[18px]`}>
          <a href="#top" className="flex items-center gap-2.5 text-[19px] font-bold tracking-[-0.01em] text-text">
            <span aria-hidden="true" className="flex size-[30px] items-center justify-center rounded-[9px] bg-accent text-base font-extrabold text-ink">
              F
            </span>
            Frontbot
          </a>
          <div className="flex flex-wrap items-center gap-7 text-[15px]">
            <a href="#features" className="text-muted hover:text-text">Features</a>
            <a href="#how" className="text-muted hover:text-text">How it works</a>
            <a href="#lab" className="text-muted hover:text-text">Lab</a>
            <a href="#privacy" className="text-muted hover:text-text">Privacy</a>
            <a href="#download" className="inline-flex min-h-11 items-center rounded-[10px] bg-text px-4 font-semibold text-ink">
              Download for Mac
            </a>
          </div>
        </nav>
      </header>

      <main>
        <section id="top" className={`${container} flex flex-col items-center gap-7 pb-16 pt-24 text-center`}>
          <p className="m-0 inline-flex items-center gap-2 rounded-full border border-edge px-3.5 py-1.5 font-mono text-[13px] text-muted">
            <span aria-hidden="true" className="size-[7px] rounded-full bg-accent" />
            For macOS 15 · Apple Silicon
          </p>
          <h1 className="m-0 max-w-[960px] text-[clamp(44px,7vw,88px)] font-extrabold leading-[1.02] tracking-[-0.04em]">
            Your team of <span className="text-accent">AI agents</span>, on your Mac.
          </h1>
          <p className="m-0 max-w-[640px] text-xl text-muted">
            Frontbot writes and plans social posts for your brands, researches topics and business ideas, and
            handles your daily tasks. Nothing gets published until you click.
          </p>
          <div className="flex flex-wrap justify-center gap-3">
            <a href={DOWNLOAD_URL} className="inline-flex min-h-12 items-center gap-2.5 rounded-xl bg-accent px-6 font-bold text-ink">
              <DownloadIcon />
              Download for Mac
            </a>
            <a href="#video" className="inline-flex min-h-12 items-center gap-2.5 rounded-xl border border-strong-edge px-[22px] font-semibold text-text">
              <svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M7 4v16l13-8z" />
              </svg>
              Watch the 90-second demo
            </a>
          </div>
          <p className="m-0 text-sm text-faint">Free download · Bring your own Anthropic API key, or use Claude Code</p>
        </section>

        <section id="video" aria-label="Product demo" className={`${container} pb-24`}>
          <a href={VIDEO_URL} className="relative block overflow-hidden rounded-[20px] border border-edge">
            <Image
              src="/frontbot-presentation.jpg"
              alt="The Frontbot app on a Mac: chat with agents, a sidebar with brands Café Sol and Northwind Studio, and the Frontbot mascot"
              width={1280}
              height={720}
              priority
              className="block aspect-video h-auto w-full object-cover"
            />
            <span className="absolute bottom-6 left-6 inline-flex items-center gap-2.5 rounded-full border border-strong-edge bg-ink/80 px-4 py-2.5 text-[15px] font-semibold text-text">
              <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
                <path d="M7 4v16l13-8z" />
              </svg>
              Play demo · 1:30
            </span>
          </a>
        </section>

        <section aria-label="Promises" className="border-y border-line bg-panel">
          <div className={`${container} grid grid-cols-[repeat(auto-fit,minmax(240px,1fr))] gap-8 py-10`}>
            {promises.map((p) => (
              <div key={p.title} className="flex flex-col gap-1.5">
                <p className="m-0 text-lg font-bold">{p.title}</p>
                <p className="m-0 text-[15px] text-muted">{p.body}</p>
              </div>
            ))}
          </div>
        </section>

        <section id="features" className={`${container} flex flex-col gap-12 pb-24 pt-28`}>
          <div className="flex max-w-[720px] flex-col gap-3.5">
            <Eyebrow>What it does</Eyebrow>
            <SectionTitle>One app for content, research and getting things done.</SectionTitle>
          </div>
          <div className="grid grid-cols-[repeat(auto-fit,minmax(300px,1fr))] gap-4">
            {features.map((f) => (
              <div key={f.title} className="flex flex-col gap-3 rounded-[18px] border border-[#26222c] bg-card p-7">
                <Icon className="text-accent">{f.icon}</Icon>
                <h3 className="m-0 text-xl font-bold">{f.title}</h3>
                <p className="m-0 text-[15px] text-muted">{f.body}</p>
              </div>
            ))}
          </div>
        </section>

        <section id="how" className="border-y border-line bg-panel">
          <div className={`${container} flex flex-col gap-12 py-28`}>
            <div className="flex max-w-[720px] flex-col gap-3.5">
              <Eyebrow>How it works</Eyebrow>
              <SectionTitle>From brand guide to published post in three steps.</SectionTitle>
            </div>
            <ol className="m-0 grid list-none grid-cols-[repeat(auto-fit,minmax(280px,1fr))] gap-10 p-0">
              {steps.map((s, i) => (
                <li key={s.title} className="flex flex-col gap-3 border-t border-strong-edge pt-6">
                  <span className="font-mono text-sm text-accent">{String(i + 1).padStart(2, "0")}</span>
                  <h3 className="m-0 text-[22px] font-bold">{s.title}</h3>
                  <p className="m-0 text-base text-muted">{s.body}</p>
                </li>
              ))}
            </ol>
          </div>
        </section>

        <section id="lab" className={`${container} flex flex-wrap items-center gap-14 py-28`}>
          <div className="flex min-w-0 flex-[1_1_420px] flex-col gap-[18px]">
            <Eyebrow>The Lab</Eyebrow>
            <SectionTitle>Agents that get better on their own, with your sign-off.</SectionTitle>
            <p className="m-0 text-lg text-muted">
              Give an agent a topic. It studies it in short, capped sessions, keeps its evidence in a notebook, and
              suggests a new skill when something works. Nothing changes until you approve it.
            </p>
          </div>
          <div aria-label="Example of a Lab session" className="flex min-w-0 flex-[1_1_420px] flex-col gap-3.5 rounded-[20px] border border-[#26222c] bg-card p-7 text-[15px]">
            <div className="flex flex-wrap justify-between gap-3">
              <span className="font-bold">Topic: Hooks that work for cafés</span>
              <span className="font-mono text-[13px] text-muted">Session 3 of 5</span>
            </div>
            <div className="flex flex-col gap-2.5 border-t border-[#26222c] pt-3.5 text-muted">
              <p className="m-0">Notebook · 12 sources, 4 findings</p>
              <p className="m-0">A finding that keeps repeating: posts that open with a question get more saves.</p>
            </div>
            <div className="flex flex-col gap-3 rounded-[14px] border border-strong-edge bg-ink p-[18px]">
              <span className="font-semibold">Proposed skill: “Question-first captions”</span>
              <div className="flex flex-wrap gap-2.5" aria-hidden="true">
                <span className="inline-flex min-h-11 items-center rounded-[10px] bg-accent px-4 font-semibold text-ink">Approve</span>
                <span className="inline-flex min-h-11 items-center rounded-[10px] border border-strong-edge px-4 font-semibold">
                  See the evidence
                </span>
              </div>
            </div>
          </div>
        </section>

        <section id="privacy" className="border-y border-line bg-panel">
          <div className={`${container} flex flex-col gap-12 py-28`}>
            <div className="flex max-w-[720px] flex-col gap-3.5">
              <Eyebrow>Privacy and safety</Eyebrow>
              <SectionTitle>Powerful agents with clear limits.</SectionTitle>
            </div>
            <div className="grid grid-cols-[repeat(auto-fit,minmax(240px,1fr))] gap-8">
              {safety.map((s) => (
                <div key={s.title} className="flex flex-col gap-2">
                  <h3 className="m-0 text-lg font-bold">{s.title}</h3>
                  <p className="m-0 text-[15px] text-muted">{s.body}</p>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section id="download" className={`${container} flex flex-col items-center gap-6 py-32 text-center`}>
          <h2 className="m-0 max-w-[860px] text-[clamp(40px,6vw,72px)] font-extrabold leading-[1.02] tracking-[-0.04em]">
            Bring your team of agents to your Mac.
          </h2>
          <p className="m-0 max-w-[560px] text-lg text-muted">
            Set up takes about two minutes: add your API key, create your first brand, and start with a suggested
            prompt.
          </p>
          <a href={DOWNLOAD_URL} className="inline-flex min-h-[52px] items-center gap-2.5 rounded-[14px] bg-accent px-7 text-lg font-bold text-ink">
            <DownloadIcon />
            Download Frontbot
          </a>
          <p className="m-0 text-sm text-faint">
            Requires macOS 15 or later on Apple Silicon, plus an Anthropic API key or Claude Code signed in.
          </p>
          <div id="install" className="mt-10 w-full max-w-[720px] rounded-[20px] border border-[#26222c] bg-card p-7 text-left">
            <h3 className="m-0 text-xl font-bold">Opening Frontbot the first time</h3>
            <p className="mb-0 mt-2 text-[15px] text-muted">
              Frontbot is free and open source, and it isn&apos;t notarized by Apple yet, so macOS asks you to confirm
              once.
            </p>
            <ol className="mb-0 mt-5 flex list-none flex-col gap-4 p-0 text-[15px]">
              {installSteps.map((step, i) => (
                <li key={i} className="flex gap-4">
                  <span className="font-mono text-sm text-accent">{String(i + 1).padStart(2, "0")}</span>
                  <span className="text-muted">{step}</span>
                </li>
              ))}
            </ol>
            <p className="mb-0 mt-5 text-sm text-faint">
              The source code is on{" "}
              <a href="https://github.com/el-frontend/frontbot" className="text-muted underline hover:text-text">
                GitHub
              </a>
              .
            </p>
          </div>
        </section>
      </main>

      <footer className="border-t border-line">
        <div className={`${container} flex flex-wrap justify-between gap-4 py-8 text-sm text-faint`}>
          <span>© 2026 Frontbot</span>
          <div className="flex flex-wrap gap-6">
            <a href="#privacy" className="text-muted hover:text-text">Privacy</a>
            <a href="mailto:elfrontendoficial@gmail.com" className="text-muted hover:text-text">Contact</a>
            <a href="https://github.com/el-frontend/frontbot" className="text-muted hover:text-text">GitHub</a>
          </div>
        </div>
      </footer>
    </div>
  );
}
