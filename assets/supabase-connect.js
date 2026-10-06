// Shared "connect your Supabase project" flow for the staff and member
// portals. The real connection lives in assets/supabase-config.js — once
// the gym's URL/key are filled in there, EVERY visitor (members on their
// own phones, staff on theirs) connects automatically with no setup of
// their own. localStorage is only a personal override for previewing a
// different project on one device without editing that file; it is never
// required for a real visitor and never touches the service_role key.
(function (global) {
  const STORAGE_KEY = "bg_supabase_config";

  function siteConfig() {
    const url = global.BG_SUPABASE_URL;
    const key = global.BG_SUPABASE_ANON_KEY;
    if (typeof url === "string" && typeof key === "string" && url && key) {
      return { url, key };
    }
    return null;
  }

  function readConfig() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (parsed && typeof parsed.url === "string" && typeof parsed.key === "string" && parsed.url && parsed.key) {
          return parsed;
        }
      }
    } catch (e) { /* ignore and fall through to the site-wide config */ }
    return siteConfig();
  }

  function writeConfig(url, key) {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ url: url.trim(), key: key.trim() }));
      return true;
    } catch (e) {
      return false;
    }
  }

  function clearConfig() {
    try { localStorage.removeItem(STORAGE_KEY); } catch (e) { /* ignore */ }
  }

  function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
      else if (k === "html") el.innerHTML = v;
      else el.setAttribute(k, v === true ? "" : v);
    }
    for (const kid of kids.flat()) {
      if (kid != null && kid !== false) el.append(kid.nodeType ? kid : String(kid));
    }
    return el;
  }

  // Renders the "connect your project" screen into `mountEl` and calls
  // `onConnected()` once a value has been saved. appName shows in the heading.
  function renderSetupScreen(mountEl, appName, onConnected) {
    const urlInput = h("input", { type: "url", placeholder: "https://abcd1234.supabase.co", autocomplete: "off", spellcheck: "false" });
    const keyInput = h("textarea", { placeholder: "eyJhbGciOi...", rows: "3", autocomplete: "off", spellcheck: "false" });
    const errorBox = h("p", { class: "small", style: "color:var(--red); display:none" });

    const save = () => {
      const url = urlInput.value.trim();
      const key = keyInput.value.trim();
      if (!/^https:\/\/.+\.supabase\.co\/?$/i.test(url)) {
        errorBox.textContent = "That doesn't look like a Supabase project URL — it should look like https://abcd1234.supabase.co";
        errorBox.style.display = "block";
        return;
      }
      if (key.length < 20) {
        errorBox.textContent = "That key looks too short — copy the full anon public key.";
        errorBox.style.display = "block";
        return;
      }
      writeConfig(url, key);
      onConnected();
    };

    mountEl.replaceChildren(
      h("div", { class: "setup-screen" },
        h("div", { class: "box card" },
          h("div", { class: "brand" }, "THE BIGGEST ", h("span", {}, "GYM")),
          h("h2", { style: "margin-top:4px" }, "This site isn't connected yet"),
          h("p", { class: "muted small", style: "margin-top:12px" },
            `This is ${appName}. If you're a member or trainer, there's nothing to do here — please contact the gym and check back later. If you're setting this site up for the gym, this needs to be connected once in assets/supabase-config.js so every visitor works automatically; the fields below are a local preview only (saved to this browser alone) and are not how the real site gets wired up.`),
          h("p", { class: "muted small" },
            "To create a project: go to ", h("a", { href: "https://supabase.com", target: "_blank", rel: "noopener" }, "supabase.com"),
            ", create a free project, run the migration files from backend/supabase/migrations in its SQL Editor, then open ",
            h("strong", {}, "Project Settings → API"), " and copy the two values below."),
          h("label", {}, "Project URL (local preview only)"), urlInput,
          h("label", {}, "Anon public key — never the service_role key (local preview only)"), keyInput,
          errorBox,
          h("button", { class: "btn-primary", style: "margin-top:18px; width:100%", onclick: save }, "Preview on this device"),
          h("p", { class: "muted small", style: "margin-top:16px" },
            "This only previews the connection in this browser, on this device. It does not connect the site for anyone else."))));
  }

  // Renders a small "disconnect" control that clears the saved config and reloads.
  function disconnectButton(label = "Disconnect this project") {
    return h("button", { class: "btn-ghost btn-small", onclick: () => { if (confirm("Forget the connected Supabase project on this device?")) { clearConfig(); location.reload(); } } }, label);
  }

  // ---------------------------------------------------------------------
  // Shared email/username + password auth helpers for the client and
  // staff portals. Keeping this logic in one place means both portals
  // check passwords and resolve usernames the same way.
  // ---------------------------------------------------------------------

  const GENERIC_LOGIN_ERROR = "Email/username or password is incorrect";

  // Returns an array of plain-English problems with the password, or an
  // empty array if it's acceptable. Rule: 10+ characters, and at least
  // two of {uppercase, lowercase, digit, symbol}.
  function passwordIssues(password) {
    const pw = String(password || "");
    const issues = [];
    if (pw.length < 10) issues.push("Use at least 10 characters.");
    const classes = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^a-zA-Z0-9]/].filter((re) => re.test(pw)).length;
    if (classes < 2) {
      issues.push("Mix in at least two of: lowercase letters, uppercase letters, numbers, symbols.");
    }
    return issues;
  }

  // Resolves a login identifier (email or username) to the email Supabase
  // Auth needs, then signs in. Never reveals whether the identifier or the
  // password was the problem - every failure returns the same generic
  // error message, so this never confirms whether a username/email exists.
  async function loginWithIdentifier(db, identifier, password) {
    const id = String(identifier || "").trim();
    if (!id || !password) {
      return { data: null, error: { message: GENERIC_LOGIN_ERROR } };
    }
    let email = id;
    if (!id.includes("@")) {
      try {
        const { data: resolved, error: rpcError } = await db.rpc("email_for_username", { p_username: id });
        if (rpcError || !resolved) {
          return { data: null, error: { message: GENERIC_LOGIN_ERROR } };
        }
        email = resolved;
      } catch (e) {
        return { data: null, error: { message: GENERIC_LOGIN_ERROR } };
      }
    }
    const { data, error } = await db.auth.signInWithPassword({ email, password });
    if (error) {
      return { data: null, error: { message: GENERIC_LOGIN_ERROR } };
    }
    return { data, error: null };
  }

  global.BGConnect = {
    readConfig, writeConfig, clearConfig, renderSetupScreen, disconnectButton, h,
    passwordIssues, loginWithIdentifier, GENERIC_LOGIN_ERROR,
  };
})(window);
