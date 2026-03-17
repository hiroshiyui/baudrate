# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Safe to run multiple times — uses upsert/on_conflict semantics throughout.
# Creates:
#   • Roles & permissions
#   • Admin user (admin / Password123!x)
#   • 14 sample boards
#   • 5 sample users with realistic profiles
#   • Articles from the admin and each sample user across boards

import Ecto.Query
alias Baudrate.{Repo, Content}
alias Baudrate.Setup.{Role, User}
alias Baudrate.Content.Board

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────

defmodule Seeds.Util do
  @doc "Derive a URL-safe slug from an arbitrary title string."
  def slugify(title) do
    base =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")
      |> String.slice(0, 60)

    "#{base}-#{:rand.uniform(9_999_999)}"
  end

  @doc "Return the board with the given slug, or raise."
  def board!(boards, slug) do
    Enum.find(boards, &(&1.slug == slug)) ||
      raise "Board #{slug.inspect()} not found — did seeding fail?"
  end

  @doc "Create a user directly (bypasses registration-mode check). Idempotent on username."
  def ensure_user(username, display_name, bio, role_name \\ "user") do
    case Repo.one(from u in User, where: u.username == ^username) do
      %User{} = u ->
        IO.puts("  skip user @#{username} (already exists)")
        u

      nil ->
        role = Repo.one!(from r in Role, where: r.name == ^role_name)

        {:ok, user} =
          %User{}
          |> User.registration_changeset(%{
            "username" => username,
            "password" => "Password123!x",
            "password_confirmation" => "Password123!x",
            "role_id" => role.id
          })
          |> Ecto.Changeset.cast(
            %{status: "active", display_name: display_name, bio: bio},
            [:status, :display_name, :bio]
          )
          |> Repo.insert()

        IO.puts("  created user @#{username} (#{display_name})")
        user
    end
  end

  @doc "Post an article to a board. Always creates a new article (slugs are randomised)."
  def post_article(user, board, title, body) do
    attrs = %{
      title: title,
      body: String.trim(body),
      slug: slugify(title),
      user_id: user.id,
      visibility: "public"
    }

    case Content.create_article(attrs, [board.id]) do
      {:ok, %{article: a}} ->
        IO.puts("    [@#{user.username} → #{board.slug}] #{a.title}")

      {:error, cs} ->
        IO.puts("    FAILED [#{board.slug}] #{title}: #{inspect(cs.errors)}")
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# 1. Roles & permissions
# ─────────────────────────────────────────────────────────────────────────────

IO.puts("\n==> Seeding roles & permissions")

unless Repo.exists?(from r in Role, where: r.name == "admin") do
  Baudrate.Setup.seed_roles_and_permissions()
  IO.puts("  roles seeded")
else
  IO.puts("  roles already exist, skipping")
end

# ─────────────────────────────────────────────────────────────────────────────
# 2. Admin user
# ─────────────────────────────────────────────────────────────────────────────

IO.puts("\n==> Seeding admin user")

_admin =
  case Repo.one(from u in User, join: r in assoc(u, :role), where: r.name == "admin", limit: 1) do
    %User{} = u ->
      IO.puts("  found existing admin @#{u.username}, skipping")
      u

    nil ->
      Seeds.Util.ensure_user("admin", "Administrator", "Site administrator.", "admin")
  end

# ─────────────────────────────────────────────────────────────────────────────
# 3. Boards
# ─────────────────────────────────────────────────────────────────────────────

IO.puts("\n==> Seeding boards")

boards_data = [
  %{
    name: "Technology",
    slug: "technology",
    description: "Discussions about software, hardware, and the tech industry.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  },
  %{
    name: "Programming",
    slug: "programming",
    description: "Code, algorithms, and software development topics.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  },
  %{
    name: "Open Source",
    slug: "open-source",
    description: "Free and open source software projects and community.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  },
  %{
    name: "Linux & Unix",
    slug: "linux-unix",
    description: "Linux distributions, BSD variants, and Unix-like systems.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  },
  %{
    name: "Security",
    slug: "security",
    description: "Information security, privacy, and cybersecurity discussions.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  },
  %{
    name: "Science",
    slug: "science",
    description: "Physics, chemistry, biology, and scientific discoveries.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  },
  %{
    name: "Mathematics",
    slug: "mathematics",
    description: "Pure and applied mathematics, proofs, and problem solving.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  },
  %{
    name: "Philosophy",
    slug: "philosophy",
    description: "Ethics, metaphysics, epistemology, and philosophical thought.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  },
  %{
    name: "History",
    slug: "history",
    description: "World history, archaeology, and historical events.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  },
  %{
    name: "Books & Literature",
    slug: "books",
    description: "Book recommendations, author discussions, and literary analysis.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  },
  %{
    name: "Music",
    slug: "music",
    description: "Music theory, genres, artists, and listening recommendations.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  },
  %{
    name: "Gaming",
    slug: "gaming",
    description: "Video games, board games, and game design.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  },
  %{
    name: "Off-Topic",
    slug: "off-topic",
    description: "Casual conversations and miscellaneous discussions.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  },
  %{
    name: "Meta",
    slug: "meta",
    description: "Discussions about this forum and community governance.",
    min_role_to_view: "guest",
    min_role_to_post: "user",
    ap_enabled: false
  }
]

Enum.each(boards_data, fn attrs ->
  if Repo.exists?(from b in Board, where: b.slug == ^attrs.slug) do
    IO.puts("  skip board #{attrs.slug} (already exists)")
  else
    case Content.create_board(attrs) do
      {:ok, b} -> IO.puts("  created board #{b.slug}")
      {:error, cs} -> IO.puts("  FAILED board #{attrs.slug}: #{inspect(cs.errors)}")
    end
  end
end)

# Reload boards so we have current IDs regardless of whether we just created them.
boards = Repo.all(from b in Board, where: b.slug != "sysop", order_by: [asc: b.id])

# ─────────────────────────────────────────────────────────────────────────────
# 4. Admin articles (5 per major board)
# ─────────────────────────────────────────────────────────────────────────────

IO.puts("\n==> Seeding admin articles")
admin = Repo.one!(from u in User, where: u.username == "admin")

admin_articles = [
  # technology
  {"technology", "The Rise of RISC-V: Open Hardware Architecture",
   """
   RISC-V is an open standard instruction set architecture (ISA) gaining significant momentum.
   Unlike proprietary ISAs such as x86 or ARM, RISC-V is freely available for anyone to implement.

   Major tech companies including Google, NVIDIA, and Western Digital have invested heavily.
   The architecture's modularity allows choosing only the extensions needed, making it suitable
   for everything from tiny microcontrollers to high-performance computing.

   **Key advantages:**
   - Royalty-free licensing
   - Modular extension system
   - Strong community support
   - Growing software ecosystem
   """},
  {"technology", "USB4 vs Thunderbolt 5: What's the Difference?",
   """
   Both USB4 Version 2.0 and Thunderbolt 5 offer up to 120 Gbps bandwidth, but there are key differences.

   **USB4 Version 2.0:** Up to 120 Gbps asymmetric mode, based on Thunderbolt 3 protocol, royalty-free.

   **Thunderbolt 5:** Up to 120 Gbps symmetric, Intel-certified, better latency guarantees.

   For most users the practical difference is minimal, but professionals working with external GPUs
   or high-resolution video capture will notice Thunderbolt 5's consistency advantages.
   """},
  {"technology", "AI Chips: Beyond GPUs",
   """
   The AI hardware landscape is evolving rapidly beyond traditional GPU-centric approaches.
   While NVIDIA's H100 remains dominant, purpose-built AI accelerators are emerging.

   Companies like Groq, Cerebras, and SambaNova are building specialized chips that challenge GPU
   dominance in specific workloads. Google's TPU v5 and AWS Trainium2 represent hyperscaler investment
   in proprietary AI silicon.

   The trend toward heterogeneous computing — combining CPUs, GPUs, and specialized accelerators —
   seems inevitable for next-generation AI workloads.
   """},
  {"technology", "Edge Computing: Bringing Data Processing Closer",
   """
   Edge computing represents a fundamental shift in how we process and analyze data. Rather than sending
   everything to centralized cloud data centers, edge computing pushes computation to the network's
   periphery — closer to where data is generated.

   This is critical for applications requiring low latency: autonomous vehicles, industrial automation,
   AR/VR, and smart city infrastructure. 5G expansion is accelerating edge computing adoption.
   """},
  {"technology", "The State of PC Gaming Hardware in 2026",
   """
   The PC gaming hardware market has undergone significant changes. Both AMD and NVIDIA have released
   new GPU generations, while Intel continues pushing into discrete graphics with Arc.

   Memory prices have stabilized after years of volatility, and DDR5 has become mainstream.
   NVMe SSDs with PCIe 5.0 interfaces now offer read speeds exceeding 14 GB/s.

   The big question: has the performance-per-dollar ratio improved enough to justify upgrades
   from 2022-era hardware?
   """},
  # programming
  {"programming", "Functional vs Object-Oriented: A Pragmatic Comparison",
   """
   The debate between functional and object-oriented programming often generates more heat than light.
   In practice, modern languages increasingly blend both paradigms.

   **Where FP shines:** data pipelines, concurrent code, mathematical modeling.
   **Where OOP shines:** complex domain entities, GUI applications, large team codebases.

   Languages like Scala, Rust, and modern Java incorporate both.
   The most effective programmers treat these as tools, not religions.
   """},
  {"programming", "Why I Switched from Python to Elixir for Backend Services",
   """
   After five years of Python backend development, I migrated our team's primary services to Elixir.

   The actor model via OTP genuinely changes how you think about fault tolerance. Supervisor trees
   make failures explicit and recoverable by design. Pattern matching and immutable data structures
   eliminated entire categories of bugs.

   For high-concurrency services, the performance characteristics are simply in a different league.
   Per-instance memory usage dropped 60% after migration.
   """},
  {"programming", "Understanding Memory Ownership in Rust",
   """
   Rust's ownership system eliminates entire classes of bugs at compile time.

   The three rules:
   1. Each value has exactly one owner
   2. One mutable reference OR many immutable references at a time
   3. References must not outlive their owner

   The borrow checker enforces these rules, making use-after-free, double-free, and data races
   impossible in safe Rust code.
   """},
  {"programming", "Writing Maintainable SQL: Patterns and Anti-Patterns",
   """
   **Embrace:**
   - CTEs for complex queries — readable and often optimized by modern query planners
   - Explicit column lists instead of `SELECT *`
   - Meaningful table aliases
   - Consistent naming conventions

   **Avoid:**
   - Functions on indexed columns in WHERE clauses
   - Implicit type conversions
   - Nested subqueries when CTEs would be clearer

   Good SQL is boring SQL. The goal is clarity, not cleverness.
   """},
  {"programming", "The Hidden Costs of Microservices",
   """
   Microservices solve certain organizational problems while introducing significant operational complexity.

   **Real costs often underestimated:**
   - Network latency between services
   - Distributed transaction complexity
   - Service discovery and load balancing infrastructure
   - Observability across service boundaries

   For a small team, a well-structured monolith with clear internal boundaries often delivers
   better velocity. Consider microservices when you have genuine team autonomy requirements.
   """},
  # open-source
  {"open-source", "The Economics of Open Source Sustainability",
   """
   **Dual licensing** (MySQL, Qt): commercial license fees fund development.
   **Open core** (GitLab): core is free; advanced features require paid subscriptions.
   **Foundation model** (Linux, Apache): corporate sponsorship through neutral foundations.
   **Consulting/support** (Red Hat model): the software is free; expertise is the product.

   The most dangerous position: a widely-used project maintained by a single unpaid developer.
   `left-pad` and `log4j` taught us how that ends.
   """},
  {"open-source", "Contributing to Your First Open Source Project",
   """
   **Start small:**
   - Fix typos in documentation
   - Improve error messages
   - Add missing test cases

   **Before submitting a PR:**
   - Read CONTRIBUTING.md thoroughly
   - Check existing issues for duplicates
   - Start with a discussion issue for large changes

   The goal of your first contribution isn't to write perfect code — it's to understand the
   contribution workflow and build a relationship with maintainers.
   """},
  {"open-source", "Licensing Demystified: MIT, Apache, GPL, and Beyond",
   """
   **Permissive licenses** (MIT, BSD, Apache 2.0): allow use in proprietary software.
   Apache 2.0 adds patent grant protection. Best for libraries you want widely adopted.

   **Copyleft licenses** (GPL, LGPL, AGPL): derivative works must also be open source.
   AGPL closes the "SaaS loophole." Best for protecting community contributions.

   **Important:** License compatibility matters when combining projects.
   GPL and Apache 2.0 are technically incompatible without explicit exceptions.
   """},
  {"open-source", "The Rise of Permissive Relicensing",
   """
   A concerning trend: established open source projects relicensing to more restrictive terms.
   HashiCorp moved Terraform from MPL to BUSL. Elasticsearch moved from Apache to SSPL.

   The pattern is consistent: a company builds a product on open source, grows dependent on
   cloud provider competition, then restricts usage to protect revenue.

   The community response has been equally consistent: forks. OpenTF became OpenTofu.
   OpenSearch forked from Elasticsearch.
   """},
  {"open-source", "Package Manager Security: Lessons from Supply Chain Attacks",
   """
   The `xz-utils` backdoor was a watershed moment for supply chain security. A sophisticated attacker
   spent two years building trust as a contributor before inserting a backdoor.

   **Key lessons:**
   - Maintainer identity verification matters
   - Automated binary artifacts in build scripts deserve scrutiny
   - Unusual obfuscation in build files is a red flag

   Practical improvements: SLSA provenance standards, sigstore for artifact signing, better
   dependency auditing tooling.
   """},
  # linux-unix
  {"linux-unix", "Systemd vs OpenRC: A Fair Comparison",
   """
   **Systemd strengths:** deep desktop integration, parallel service startup, widespread support.
   **OpenRC strengths:** simpler mental model, easier to debug, works on non-Linux systems.

   For server workloads where you want minimal complexity, OpenRC or runit are legitimate choices.
   For modern desktop Linux, systemd's ecosystem advantages are significant.
   """},
  {"linux-unix", "Understanding the Linux Virtual Memory System",
   """
   **Key concepts:**
   - **Page cache:** filesystem reads cached in RAM; writes buffered as dirty pages
   - **Overcommit:** Linux allows allocating more memory than physically available
   - **OOM killer:** kills processes when truly out of memory
   - **Huge pages:** 2MB pages reduce TLB pressure for large working sets

   The `vm.swappiness` parameter (0–200) controls swap tendency vs page cache reclaim —
   tuning this is often more impactful than people expect.
   """},
  {"linux-unix", "NixOS: Reproducible System Configuration",
   """
   NixOS describes the entire OS state declaratively in a configuration file; changes are applied atomically.

   The result: configurations are reproducible, rollbacks are trivial, and multiple configurations
   can coexist via generations. The tradeoff is a steep learning curve.

   For server management and development environments, the reproducibility guarantees are
   genuinely compelling.
   """},
  {"linux-unix", "Shell Scripting Best Practices in 2026",
   """
   **Always start with:**
   ```
   #!/usr/bin/env bash
   set -euo pipefail
   ```

   **Key practices:**
   - Quote all variable expansions: `"$var"` not `$var`
   - Use `[[ ]]` instead of `[ ]` for conditionals in bash
   - Use `mktemp` for temporary files, clean up with `trap`
   - ShellCheck is mandatory — run it in CI

   When your script exceeds ~200 lines, seriously consider Python or another language.
   """},
  {"linux-unix", "ZFS on Linux: A Practical Guide",
   """
   **Key ZFS features:** copy-on-write, built-in RAID (RAID-Z1/2/3), dataset snapshots,
   data integrity via checksumming, inline compression (lz4, zstd).

   **Practical recommendations:**
   - ECC RAM is strongly recommended
   - Give ARC (ZFS cache) as much RAM as possible
   - Use `zstd` compression on almost everything — it's free performance
   - Regular `zpool scrub` to detect and correct bit rot
   """},
  # security
  {"security", "Zero Trust Architecture: Principles and Implementation",
   """
   Zero Trust rejects the perimeter security model in favor of "never trust, always verify."

   **Core principles:**
   1. Verify explicitly — use all available data points (identity, location, device health)
   2. Least privilege access — limit with just-in-time and just-enough-access
   3. Assume breach — minimize blast radius, segment access, encrypt everything

   Zero Trust is a journey, not a product.
   """},
  {"security", "Understanding Modern TLS: What's Changed in TLS 1.3",
   """
   TLS 1.3 (RFC 8446) is the most significant overhaul of the TLS protocol in decades.

   **Performance:** 1-RTT handshake (vs 2-RTT in TLS 1.2); 0-RTT resumption available.

   **Security:** Removed RSA key exchange, static DH, RC4, DES, 3DES, MD5, SHA-1.
   Forward secrecy is now mandatory (ECDHE only). Encrypted certificate negotiation.

   TLS 1.3 traffic cannot be decrypted later even if the server's private key is compromised.
   """},
  {"security", "Password Managers: Threat Model and Operational Security",
   """
   **What password managers protect against:**
   - Password reuse across sites
   - Weak/guessable passwords
   - Phishing (good managers check domain, not just URL display)

   **Operational recommendations:**
   - Enable 2FA on your password manager account
   - Treat your master password as irreplaceable — memorize it
   - Review emergency access procedures
   """},
  {"security", "SQL Injection in 2026: Still Relevant?",
   """
   SQL injection was first documented in the late 1990s and remains in every OWASP Top 10.

   **Why it persists:**
   - Legacy applications predating ORMs
   - Developers bypassing ORM protections for "performance"
   - Dynamic query construction for search/reporting
   - ORM misuse: `whereRaw()`, `raw()`, string interpolation in query builders

   **Defense:** Parameterized queries, always. No exceptions.
   """},
  {"security", "Incident Response: The First 24 Hours",
   """
   **Immediate priorities:**
   1. **Contain** — isolate affected systems without destroying evidence
   2. **Assess** — what was accessed/exfiltrated?
   3. **Communicate** — notify relevant stakeholders
   4. **Document** — timestamp everything from the moment of detection

   **Common mistakes:**
   - Rebooting systems (destroys memory artifacts)
   - Deleting logs to "clean up"
   - Announcing publicly before understanding scope

   Practice your incident response plan with tabletop exercises before you need it.
   """},
  # science
  {"science", "Quantum Computing: Where We Actually Are",
   """
   **What we have:** NISQ devices with 100–1000+ qubits; demonstrations of quantum advantage
   in narrow benchmarks; no practical quantum advantage for real-world problems yet.

   **Key obstacles:** Error rates (~0.1–1%); decoherence time limits; connectivity constraints.

   **Realistic timeline:**
   - 5–10 years: fault-tolerant demonstrators
   - 10–20 years: potentially useful for drug discovery, materials science

   Cryptographically relevant quantum computers remain decades away, if achievable at all.
   """},
  {"science", "CRISPR Beyond the Hype: Clinical Applications",
   """
   **Approved therapies:** Casgevy (Vertex/CRISPR Therapeutics) for sickle cell disease and
   beta-thalassemia — the first approved CRISPR therapy.

   **Technical progress:** Base editing and prime editing offer more precise edits without
   double-strand breaks. In-vivo delivery remains the key technical challenge.

   **Ethically:** Germline editing (heritable changes) remains legally restricted in most
   jurisdictions following the He Jiankui incident.
   """},
  {"science", "The James Webb Space Telescope: Two Years of Discoveries",
   """
   **Galaxy formation:** JWST revealed massive, well-formed galaxies far earlier than standard
   cosmological models predicted, prompting significant theoretical revision.

   **Exoplanet atmospheres:** Detailed characterization of TRAPPIST-1 and dozens of other planets —
   detecting CO2, water vapor, methane in some atmospheres.

   **Star formation:** Unprecedented views of stellar nurseries revealing protoplanetary disk
   formation in detail previously impossible to observe.
   """},
  {"science", "Fusion Energy: Is This Time Different?",
   """
   **What changed:**
   - NIF achieved ignition (energy gain > 1 from laser energy) in 2022
   - Private investment: Commonwealth Fusion, Helion, TAE Technologies raised billions
   - Alternative confinement approaches advancing in parallel

   **Remaining challenges:**
   - Energy gain from wall plug (total system efficiency)
   - Tritium breeding at commercial scale
   - Materials under neutron bombardment

   Cautious optimism is warranted. Commercial fusion by 2040 is plausible, not guaranteed.
   """},
  {"science", "Microbiome Research: What the Science Actually Shows",
   """
   **Well-established:**
   - Gut microbiome influences immune system development
   - FMT is highly effective for recurrent C. difficile infection
   - Antibiotic disruption has measurable health effects

   **Promising but preliminary:** Gut-brain axis connections; obesity associations.

   **Oversold:**
   - Most commercial probiotics have limited evidence for specific health claims
   - Microbiome testing services offering actionable health advice lack clinical validation

   The field is exciting; the commercial ecosystem has outrun the science.
   """},
  # mathematics
  {"mathematics", "The Riemann Hypothesis: Why It Matters",
   """
   The Riemann Hypothesis (1859) remains unproven and is arguably the most important unsolved
   problem in mathematics.

   All non-trivial zeros of the Riemann zeta function appear to lie on the critical line Re(s) = 1/2.
   The distribution of prime numbers is intimately connected to these zeros.

   Roughly 1000 mathematical theorems begin with "assuming RH..." — the hypothesis has been verified
   computationally for the first 10^13 zeros, all on the critical line. Verification is not proof.
   """},
  {"mathematics", "Graph Theory in Everyday Infrastructure",
   """
   Graph theory underlies infrastructure we use daily:

   **Navigation:** Dijkstra's and A* find optimal routes. Road networks are weighted directed graphs.
   **Internet routing:** BGP uses path-vector routing across the internet's autonomous system topology.
   **Social networks:** Friend recommendations via common neighbor analysis.
   **Chip design:** Circuit layout optimization is a graph embedding problem.

   The four color theorem (any planar map needs ≤4 colors) was the first major theorem proved
   with computer assistance (1976).
   """},
  {"mathematics", "An Introduction to Category Theory",
   """
   Category theory provides a unifying language for mathematics by focusing on relationships
   between structures rather than the structures themselves.

   A **category** consists of objects, morphisms between objects, composition, and identity morphisms.
   A **functor** maps between categories preserving structure.
   A **natural transformation** maps between functors.

   **Why programmers care:** Monads are monoids in the category of endofunctors.
   Category theory gives a precise language for discussing abstraction over computation.
   """},
  {"mathematics", "Gödel's Incompleteness Theorems: What They Do and Don't Say",
   """
   **First incompleteness theorem:** Any consistent formal system sufficiently powerful to express
   basic arithmetic contains statements that are true but unprovable within that system.

   **Second incompleteness theorem:** Such a system cannot prove its own consistency.

   **What they DON'T say:**
   - "Mathematics is broken"
   - "Truth is subjective"
   - That human intuition exceeds formal systems

   The theorems apply to formal systems, not to mathematical truth itself.
   """},
  {"mathematics", "The Mathematics of Voting Systems",
   """
   Arrow's Impossibility Theorem (1951) proved that no ranked voting system can simultaneously
   satisfy all of a small set of reasonable fairness criteria when there are ≥3 candidates.

   **Arrow's criteria:**
   1. Non-dictatorship
   2. Pareto efficiency
   3. Independence of irrelevant alternatives

   **Common systems and their failure modes:**
   - Plurality: fails IIA dramatically, enables strategic voting
   - Instant-runoff: fails IIA, non-monotonicity possible
   - Condorcet methods: fail when there's a Condorcet cycle

   There is no perfect voting system.
   """},
  # philosophy
  {"philosophy", "Free Will and Determinism in the Age of Neuroscience",
   """
   Modern neuroscience has reignited the ancient debate. The Libet experiments show unconscious
   brain activity precedes conscious awareness of decisions.

   **Hard determinism:** All events are caused by prior causes; free will is illusory.
   **Compatibilism:** Free will is compatible with determinism — acting freely means acting according
   to your own desires without external compulsion.
   **Libertarian free will:** Genuine agent causation exists, distinct from physical causation.

   The compatibilist position (Hume, Kant, Dennett) argues the neuroscience debate attacks a strawman.
   """},
  {"philosophy", "The Ethics of Artificial Intelligence: A Philosophical Survey",
   """
   **Consequentialist approaches:** Evaluate AI by outcomes — utility maximization.
   **Deontological approaches:** Rules-based constraints regardless of consequences; prohibitions
   on deception, manipulation, violation of autonomy.
   **Virtue ethics approaches:** What kinds of systems and practices reflect good character.

   **Distinctive AI challenges:**
   - Opacity: evaluating what we can't understand
   - Scale: single systems affecting billions
   - Autonomy: machines making consequential decisions without human review

   No single framework is adequate.
   """},
  {"philosophy", "Epistemology for the Information Age",
   """
   Traditional epistemology asked: what is knowledge? How do we justify belief?
   These questions have new urgency in an environment of information overload and algorithmic curation.

   **Contemporary challenges:**
   - How does algorithmic recommendation affect epistemic diversity?
   - What epistemological status do AI-generated claims have?
   - How should we reason under deep uncertainty?

   Virtue epistemology — focusing on epistemic character traits (intellectual humility, open-mindedness)
   rather than just true beliefs — offers useful resources.
   """},
  {"philosophy", "Stoicism in the 21st Century: Philosophy as Practice",
   """
   **Core Stoic claims:**
   - Some things are "up to us" (judgments, intentions); most things are not
   - Virtue is the only genuine good; externals are "preferred indifferents"
   - Emotions that cause suffering arise from false judgments about value

   **What the pop revival gets right:** Stoic practices — negative visualization, memento mori,
   the view from above — are genuinely useful psychological tools.

   **What it often misses:** Stoicism is a complete ethical system, not a stress management technique.
   """},
  {"philosophy", "Personal Identity: The Ship of Theseus Problem for Persons",
   """
   Applied to persons: we are constituted by constantly changing matter. What persists?

   **Psychological continuity** (Locke, Parfit): identity consists in overlapping chains of
   psychological connections — memories, intentions, personality.

   **Biological continuity:** the organism itself is what persists.

   **Narrative identity** (Ricoeur): the self is the character of a story we tell.

   Parfit's conclusion — that personal identity isn't what matters — has radical implications
   for how we think about death, desert, and future obligations.
   """},
  # history
  {"history", "The Bronze Age Collapse: History's Most Mysterious Catastrophe",
   """
   Around 1200 BCE, Bronze Age Mediterranean civilizations collapsed within decades of each other.

   **Evidence for multiple causes:**
   - Sea Peoples invasions (described in Egyptian records)
   - Prolonged drought (paleoclimatological evidence)
   - Earthquakes (destruction layers at multiple sites)
   - Trade network collapse — the Bronze Age economy was highly interconnected

   The "systems collapse" model argues no single cause is sufficient — the interaction of multiple
   stressors was catastrophic. A lesson in civilizational fragility.
   """},
  {"history", "The Printing Press and Information Revolutions",
   """
   Gutenberg's printing press (c. 1440) caused: standardization of language; explosion of literacy
   (gradually); the Protestant Reformation; the Scientific Revolution; a century of religious warfare.

   **The "information revolution" pattern:**
   Both the printing press and the internet enabled democratization of information production,
   followed by: information overload, quality crisis, political disruption, and eventual partial
   stabilization through new institutions.

   The Reformation's parallels to contemporary political polarization aren't coincidental.
   """},
  {"history", "Ancient Rome's Infrastructure Legacy",
   """
   **Roads:** The Roman road network (400,000+ km) established routes that became medieval trade
   paths, which became modern highways.

   **Law:** Roman law, preserved through Justinian's Corpus Juris Civilis, forms the basis of civil
   law traditions across continental Europe and Latin America.

   **Concrete:** Roman concrete using volcanic ash pozzolan remains partially intact in marine
   environments 2000 years later. Modern concrete in seawater degrades in decades.
   """},
  {"history", "The Columbian Exchange: Biological Globalization",
   """
   **From Americas to Old World:** Potatoes, maize, tomatoes, peppers, chocolate, tobacco.

   **From Old World to Americas:** Smallpox, measles, influenza (90%+ mortality in some indigenous
   populations); horses, cattle, pigs; sugar cane (drove Atlantic slave trade expansion).

   The death toll from introduced diseases — estimated 50–90 million people in the Americas —
   makes the Columbian Exchange history's deadliest biological event, far exceeding any war.
   """},
  {"history", "The History of Cryptography: From Caesar to Quantum",
   """
   **Ancient to Renaissance:** Caesar cipher, Vigenère cipher, Enigma machine — each defeated by pattern analysis.

   **WWII:** Breaking Enigma at Bletchley Park (led by Turing) is estimated to have shortened the war
   by 2–4 years. The work remained secret until 1974.

   **Public key revolution (1970s):** Diffie-Hellman and RSA made secure communication between
   strangers possible without prior key exchange — enabling the modern internet.

   **Post-quantum:** NIST finalized post-quantum standards in 2024. Migration is now urgent infrastructure.
   """},
  # books
  {"books", "Reading Against the Algorithm: Rediscovering Long-form Attention",
   """
   The attention economy has made sustained reading genuinely difficult for many people.

   **What research suggests:**
   - Smartphones and social media correlate with decreased reading for pleasure
   - The "shallowing" effect is real but appears partially reversible with practice
   - Physical books outperform screens for comprehension and retention

   **Practical recovery:**
   - Treat reading time as protected, not residual
   - Start with re-reads of beloved books — familiar territory requires less cognitive load

   The ability to follow a sustained argument or narrative is trainable.
   """},
  {"books", "Science Fiction That Predicted the Present",
   """
   SF's power isn't prediction but extrapolation — following implications of present conditions
   to logical conclusions.

   **Surveillance:** Orwell's *1984* (1949); Brunner's *The Shockwave Rider* (1975).
   **Social media:** Vinge's *A Fire Upon the Deep* (1992).
   **Climate:** Robinson's *The Ministry for the Future* (2020).

   The best SF doesn't predict specific technologies but captures how technologies reshape social relations.
   """},
  {"books", "Non-Fiction Worth Reading: Overlooked Gems",
   """
   **History:** *Longitude* (Sobel); *The Worst Hard Time* (Egan) — the Dust Bowl through survivors.
   **Science:** *The Particle at the End of the Universe* (Carroll); *Entangled Life* (Sheldrake) — fungi.
   **Economics:** *The Worldly Philosophers* (Heilbroner); *Debt: The First 5,000 Years* (Graeber).
   **Philosophy:** *Gödel, Escher, Bach* (Hofstadter) — consciousness, recursion, self-reference.

   What underloved books have shaped your thinking?
   """},
  {"books", "The Art of the Literary Essay",
   """
   Montaigne invented the essay form in 1580 as honest self-examination.
   "Every man carries the entire form of the human condition within himself."

   **The form's distinctive properties:**
   - Personal experience used to access universal concerns
   - Irresolution is permitted — essays can end without conclusions
   - Association and digression are features, not bugs

   **Contemporary masters:** James Baldwin, Joan Didion, Annie Dillard, Zadie Smith.
   The essay form has migrated to the internet in degraded form (the "hot take"), but genuine
   examples thrive in literary magazines.
   """},
  {"books", "Translating Literature: The Invisible Art",
   """
   Every translated book is at minimum two books: the original and the translation.
   The "same" novel translated by different hands can be radically different reading experiences.

   **Translation philosophy spectrum:**
   - **Foreignizing** (Venuti): preserve the strangeness; let the reader do work
   - **Domesticating** (Nida): produce equivalent effect; clarity over fidelity

   **Example:** Constance Garnett's Tolstoy vs. Pevear and Volokhonsky's — very different experiences.
   When you read a translated book, you're reading the translator as much as the author.
   """},
  # music
  {"music", "How Streaming Changed What Music Gets Made",
   """
   Streaming platforms pay per stream, creating economic incentives that have measurably changed music.

   **Observable changes:**
   - Songs are getting shorter (average pop song length declined ~30s since 2000)
   - Intros are disappearing — hooks must arrive in the first 15–30 seconds (before skip)
   - Genre blending accelerated — algorithms surface "mood" playlists, not genre bins

   A 1-minute song earns proportionally more per album play than a 6-minute song.
   Some artists explicitly game this.
   """},
  {"music", "Music Theory: The Circle of Fifths Explained",
   """
   Starting from C, moving clockwise adds one sharp per key; counterclockwise adds one flat.

   **Practical uses:**
   - **Key signatures:** count to the key's position to find sharps/flats
   - **Chord progressions:** adjacent keys have strong harmonic relationships (ii–V–I)
   - **Modulation:** adjacent keys sound smooth; distant keys sound dramatic
   - **Song analysis:** identifying key center and secondary dominants

   The circle encodes centuries of Western harmonic practice.
   """},
  {"music", "The History of Electronic Music",
   """
   Electronic music is over a century old.

   **Pre-synthesizer:** Theremin (1920); Ondes Martenot (1928); Musique concrète (Paris, 1940s).

   **Synthesizer era:** Moog's commercial synthesizer (1970). Wendy Carlos's *Switched-On Bach* (1968).

   **Drum machines:** Roland TR-808 (1980) and TR-909 (1981) — initially commercial failures —
   became the sonic foundation of hip-hop, house, and techno.

   **Personal computers:** MIDI standardization (1983) connected synthesizers to computers.
   """},
  {"music", "What Makes Jazz Improvisation Work",
   """
   Jazz improvisation is more structured than it appears.

   **The fundamental structure:** Improvisers play over chord changes. The harmony is the constraint
   and canvas. A standard is really a series of chord changes over which any melody can be improvised.

   **The vocabulary:** Jazz improvisation draws on learned patterns — scales, arpeggios, licks.
   Beginners string vocabulary together; masters transform it.

   Charlie Parker could play the same standard 50 times and never repeat himself —
   not through randomness but through inexhaustible melodic imagination.
   """},
  {"music", "Listening Deeply: Building a Music Appreciation Practice",
   """
   Most of us hear music; few of us listen to it.

   **Active listening:** Choose one piece. Sit with it entirely. First pass: follow the melody.
   Second pass: follow the bass. Third pass: follow the rhythm. Fourth pass: the interaction.

   **Cross-genre exposure:** Deliberately expanding range reveals music's vast territory.
   Start with adjacent genres (jazz → blues → gospel → soul).

   **Learning an instrument (even badly):** Even basic understanding transforms listening.
   Appreciation is a skill, not a preference. It's built through directed attention over time.
   """},
  # gaming
  {"gaming", "The Design Philosophy Behind FromSoftware Games",
   """
   FromSoftware's games are often framed as "difficult" — that framing misses what's distinctive.

   **Core design principles:**
   - **Discovery over explanation:** information embedded in environment, not tutorials
   - **Death as information:** failure teaches; it's feedback not punishment
   - **Mastery as progression:** the game gets easier because you understand it, not because you level up
   - **Environmental storytelling:** lore reconstructed from fragments across playthroughs

   A sense of earned accomplishment unavailable when content is scaled to the player.
   """},
  {"gaming", "Indie Games That Redefined Their Genres",
   """
   Indie games have repeatedly shown that small teams with clear vision outperform major studios
   constrained by development risk.

   **Roguelikes:** *Spelunky* (2012) and *Hades* (2020) — procedural generation with emotional depth.
   **Narrative:** *Disco Elysium* (2019) — RPG dialogue and political writing into literary territory.
   **Platformers:** *Celeste* (2018) — precision platforming and mental health narrative.
   **Metroidvanias:** *Hollow Knight* (2017) — small team, classic-rivaling world.

   The pattern: clear design vision, willingness to let mechanics carry meaning.
   """},
  {"gaming", "Game Preservation: The Medium That Forgets Itself",
   """
   More than 87% of classic video games are out of print and unavailable through legitimate channels.

   **The technical problem:** Hardware obsolescence, DRM requiring defunct servers, proprietary formats,
   physical media degradation.

   **The legal problem:** Copyright term extension means games from the early 1990s won't enter
   the public domain until the 2080s. The DMCA creates chilling effects on preservation work.

   Games represent a significant cultural and artistic form.
   Losing them is equivalent to losing films or books — and we're losing them at massive scale.
   """},
  {"gaming", "Speedrunning: Games as Athletic Pursuit",
   """
   Speedrunning — completing games as fast as possible — has grown from niche hobby to major cultural
   phenomenon with Games Done Quick raising millions for charity annually.

   **The skill dimensions:** Execution (precise repeatable inputs), game knowledge (every system and glitch),
   routing (optimal paths), mental game (performance under pressure).

   **What speedrunning reveals:**
   Games are systems. Speedrunning is the practice of understanding those systems thoroughly enough
   to exploit every property. It's a form of close reading.
   """},
  {"gaming", "The Future of Game AI: Beyond Chess Engines",
   """
   DeepMind's AlphaStar (StarCraft II) and OpenAI Five (Dota 2) demonstrated that real-time
   strategy games yield to reinforcement learning.

   **What's coming:**
   - NPCs with context-aware dialogue via LLMs
   - Procedural content generation guided by player behavior models
   - Dynamic difficulty adaptation based on frustration/boredom detection
   - AI game masters for tabletop RPG-style narrative adaptation

   **The open question:**
   Does AI-generated content produce experiences players find meaningful?
   """},
  # off-topic
  {"off-topic", "The Case for Boredom",
   """
   Boredom has been pathologized. Modern environments treat it as a problem to be solved — there's
   always a screen available to fill empty time. This may be a mistake.

   Research shows boredom precedes creative ideation. The "default mode network" — active during
   mind-wandering — is associated with autobiographical memory, future planning, and creative problem solving.

   **A modest proposal:** Take one 20-minute walk per day without headphones or a phone.
   Resist the urge to fill the silence. The discomfort is the point.
   """},
  {"off-topic", "Why Does Coffee Taste Better When Someone Else Makes It?",
   """
   **The expectation effect:** Anticipation shapes taste experience. Novelty enhances flavor.

   **The effort effect (reversed):** Things we didn't work for can taste better. The labor of making
   your own coffee primes critical evaluation rather than appreciation.

   **The social dimension:** Coffee made for you is an act of care. Context activates different
   neural pathways than solo consumption.

   **The actual chemistry:** If the coffee genuinely tastes better, the maker may be more skilled,
   use better equipment, or simply extract at a different ratio than you would for yourself.
   """},
  {"off-topic", "The Surprising History of Ordinary Objects",
   """
   **The pencil:** The graphite deposit found in Borrowdale (1560s) was so pure it could write
   without burning. Modern pencils contain no lead.

   **The safety pin:** Walter Hunt invented it in 1849 to pay off a $15 debt.
   He assigned the patent for $400. The creditor made a fortune.

   **Blue jeans:** Levi Strauss and Jacob Davis patented riveted work pants in 1873 for gold miners.
   The rivets reinforced stress points. The style became countercultural symbolism 80 years later.

   What objects in your daily life do you know the actual history of?
   """},
  {"off-topic", "Learning New Skills as an Adult: What Actually Works",
   """
   **What actually works:**
   - Spaced repetition for declarative knowledge
   - Deliberate practice with feedback, not just repetition
   - Interleaving related skills rather than blocking practice
   - Sleep is non-negotiable for consolidation

   **The main barrier to adult learning** isn't neurological; it's that adults have more responsibilities,
   more embarrassment about failure, and less structured feedback than children in school.

   Neuroplasticity doesn't stop in adulthood — it changes character.
   """},
  {"off-topic", "Night Owls vs Early Birds: What Research Shows",
   """
   Circadian preference is substantially heritable — being a "night owl" isn't laziness, it's partly biology.

   **What chronotype predicts:**
   - Peak cognitive performance timing varies ~4 hours between extreme chronotypes
   - Night owls perform comparably to morning types when tested at their optimal time
   - Social jet lag (mismatch between chronotype and social schedule) predicts health problems

   **What doesn't change this:**
   Light exposure and habit can shift chronotype somewhat (30–60 minutes typically).
   Extreme owls shifting to extreme larks is not supported by evidence.
   """},
  # meta
  {"meta", "What Makes an Online Community Work?",
   """
   **Factors that predict success:**
   - Clear purpose: specific, defined focus maintains coherence
   - Contribution norms: explicit or implicit standards about participation quality
   - Effective moderation: context-aware, consistent, explanatory
   - Critical mass with manageable size

   **What kills communities:**
   - Controversy without resolution mechanisms
   - Moderation capture (moderators serving cliques)
   - Platform changes that alter incentive structures
   - Successful growth exceeding capacity to socialize newcomers
   """},
  {"meta", "On Writing for the Internet",
   """
   **The skim assumption:** Online readers scan. Effective online writing compensates: clear headers,
   strong opening sentences, concise paragraphs.

   **The link:** Hyperlinks change reading experience fundamentally — they offer escapes, imply context.
   Use links purposefully, not decoratively.

   **The permanence paradox:** Digital text is both more durable (copies proliferate) and more fragile
   (link rot, platform shutdowns). Write as if your words will be read out of context.

   Good writing remains: clear argument, honest engagement, genuine interest in your subject.
   """},
  {"meta", "Why BBS Culture Matters in 2026",
   """
   Bulletin Board Systems predated the web. Before HTTP, people called into local BBSs via modem
   and exchanged ideas in threaded text discussions.

   **What BBSs got right:**
   - Geographic community: local BBSs connected neighbors, not global strangers
   - Persistence: conversations accumulated into searchable history
   - SysOp accountability: someone owned and ran the system, with real responsibility

   Smaller, intentional communities with genuine moderation may be more valuable than the global
   social-media-as-public-square experiment, which has largely failed.
   """},
  {"meta", "Feedback as a Feature, Not a Bug",
   """
   **What good feedback includes:**
   - Specificity: "the third paragraph loses me" not "confusing"
   - Descriptive not evaluative: what happened, not what's wrong with the author
   - Focus on the work, not the person
   - Acknowledgment of what's working alongside what isn't

   **Receiving feedback:**
   Learn to separate ego from work, ask clarifying questions before responding,
   and sit with discomfort before deciding what to incorporate.

   In online contexts: err toward explicit kindness in framing. Assume good faith until demonstrated otherwise.
   """},
  {"meta", "Community Guidelines: Principles Over Rules",
   """
   Most online community guidelines fail because they're lists of prohibited behaviors
   rather than statements of shared values.

   **Principles-based approach:**
   State what the community is for and what kind of participation makes it better.
   "We assume good faith until demonstrated otherwise" is more generative than "no personal attacks."

   **Elements of effective community guidelines:**
   - Purpose statement: what is this community for?
   - Positive norms: describe the behavior you want, not just what you don't
   - Consequence transparency: what happens when norms are violated?
   - Living document: guidelines should evolve as the community learns
   """}
]

Enum.each(admin_articles, fn {board_slug, title, body} ->
  board = Seeds.Util.board!(boards, board_slug)
  Seeds.Util.post_article(admin, board, title, body)
end)

# ─────────────────────────────────────────────────────────────────────────────
# 5. Sample users + their articles
# ─────────────────────────────────────────────────────────────────────────────

IO.puts("\n==> Seeding sample users and their articles")

users_data = [
  {
    "alice_dev",
    "Alice Chen",
    "Full-stack developer who loves Elixir and distributed systems. " <>
      "Occasional contributor to open source projects on weekends.",
    [
      {"technology", "The Ergonomic Keyboard Rabbit Hole",
       """
       I fell into the ergonomic keyboard rabbit hole six months ago and I'm not sure I've found the bottom yet.

       It started with wrist pain during a particularly intense project sprint. My doctor suggested an ergonomic keyboard.
       What followed was weeks of research into split keyboards, columnar stagger, thumb clusters, and key switch physics.

       **What I settled on:**
       A custom-built Dactyl Manuform with Boba U4 switches (silent tactile) and a Colemak-DH layout.
       The relearning curve took about three weeks to reach proficiency, another six to match my former QWERTY speed.

       Is it worth it? My wrists say yes. My colleagues say the keyboard looks like something from a sci-fi prop department.
       """},
      {"programming", "Lessons from Rewriting a Rails App in Phoenix",
       """
       After four years maintaining a mid-sized Rails application, our team made the decision to rewrite in Phoenix/Elixir.
       Here's an honest retrospective 18 months later.

       **What we expected:** Better concurrency, lower memory footprint, more maintainable code.

       **What we got:** All of the above, plus things we didn't anticipate: the supervision tree makes reasoning
       about failure modes explicit, pattern matching reduced our conditional logic dramatically, and Ecto changesets
       make validation logic composable.

       **The hard part:** Hiring. The Phoenix talent pool is smaller. We've compensated by hiring strong Elixir
       generalists and cross-training rather than seeking Phoenix specialists.
       """},
      {"open-source", "My First Hex Package: A Retrospective",
       """
       I published my first Hex package eight months ago — a small library for parsing and validating IETF language tags (BCP 47).
       Nobody asked for it; I needed it for a project and nothing adequate existed.

       **Lessons:**
       - The `@doc` and `@moduledoc` you write at the start will be wrong by the time you finish. Write them last.
       - ExDoc generates beautiful documentation. Use it, configure it properly, include example-heavy doctests.
       - Semantic versioning is a contract. Breaking it, even accidentally, breaks user trust.

       Eight months in: 340 downloads/week, three external contributors, two bugs reported and fixed.
       Small but useful. That's enough.
       """},
      {"linux-unix", "Three Years Running NixOS as My Daily Driver",
       """
       Three years ago I switched my primary workstation from Arch Linux to NixOS. People ask if I regret it.

       **The short answer:** No.

       The payoff: my entire system — every installed package, every service, every configuration file — lives in
       a git repository. I can reproduce my exact environment on any machine in minutes. Rolling back a broken system
       update is one command.

       The tradeoff: some software doesn't package well for Nix. Commercial applications with proprietary dependencies
       require workarounds.

       Would I recommend it? For someone comfortable with Linux and willing to invest learning time: yes, absolutely.
       """},
      {"meta", "How I Use This Forum: A Personal Workflow",
       """
       I've been on various forums and community platforms over the years. Here's how I've learned to use this one well.

       **Reading before posting:** I try to read a board for at least a week before posting in it. Understanding
       the community's norms, what's been discussed recently, and who the regular contributors are saves me from
       redundant posts and social missteps.

       **Long-form over short-form:** I've found that longer, more developed posts get better engagement and generate
       more interesting conversations than quick takes.

       What are other people's forum habits?
       """}
    ]
  },
  {
    "bob_sysadmin",
    "Robert Kowalski",
    "Linux sysadmin by day, amateur radio operator by night (KD9XYZ). " <>
      "Obsessed with reliability engineering and home lab experiments.",
    [
      {"linux-unix", "My Home Lab Setup: Lessons Learned",
       """
       I've been running a home lab for six years. What started as a single repurposed desktop has grown into a
       12-node setup consuming more electricity than I'd like to admit.

       **Current hardware:**
       - 3× Dell PowerEdge R620 (hypervisor cluster, Proxmox VE)
       - 2× Raspberry Pi 5 (edge services, PiHole, monitoring)
       - 1× custom NAS (TrueNAS Scale, 48TB usable)

       **What I've learned:**
       1. Networking is the foundation. A bad switch or misconfigured VLAN breaks everything above it.
       2. Backups are not optional. I've had two drive failures. Both recoverable.
       3. Monitoring matters. I run Prometheus + Grafana + Alertmanager.
       4. Power costs accumulate. Old server hardware is cheap to buy and expensive to run.
       """},
      {"security", "Why I Moved My Home Network to VLANs",
       """
       Six months ago I segmented my home network into VLANs. Here's what prompted it and what I learned.

       **The trigger:** My smart TV was making outbound connections to servers in five countries.

       **My VLAN structure:**
       - Trusted (laptops, phones): full internet + LAN access
       - IoT (smart TV, thermostats): internet access only, no LAN
       - Guest: internet only, isolated from everything
       - Lab (home servers): LAN access, restricted internet
       - Management (switch, AP): no internet

       **Required hardware:** A VLAN-capable managed switch and a router that supports 802.1Q.
       I use a Mikrotik hAP ax3 + cheap managed switch. pfSense handles firewall rules between VLANs.
       """},
      {"technology", "The Case for Boring Technology",
       """
       Dan McKinley's "Choose Boring Technology" essay is one of the most useful things written about software engineering.

       **The core argument:** Every new technology you adopt comes with a "novelty budget" — accumulated unknowns
       about how it behaves under real conditions, how it fails, how to operate it. Boring technology has a known
       failure mode catalog. Exciting technology surprises you in production at 3 AM.

       **In practice:** Our team prefers technology with >5 years of widespread production use for infrastructure components.

       The most reliable systems I've operated are also, almost without exception, the most boring ones.
       """},
      {"science", "Amateur Radio and Ionospheric Propagation",
       """
       One thing amateur radio teaches you that you can't get from textbooks alone: real respect for atmospheric physics.

       **What ionospheric propagation means:** Radio waves at certain frequencies (3–30 MHz) can reflect off the ionosphere,
       allowing communication over thousands of kilometers with modest power.

       **Why it's unpredictable:** The ionosphere is driven by solar activity. Solar flares cause sudden ionospheric
       disturbances that can wipe out HF communication within minutes.

       **What this teaches:** The gap between theory and practice. You understand physics differently when
       you're using it to make something work.
       """},
      {"off-topic", "The Satisfaction of Fixing Old Hardware",
       """
       I have a problem: I cannot throw away old hardware without trying to fix it first.

       This weekend's project: a ThinkPad T440p from 2014 with a failed keyboard and a dead CMOS battery.
       Two hours, $12 in parts, and the machine that was headed for landfill is now running Debian.

       **Why this matters:** Beyond the obvious environmental argument, there's something genuinely satisfying
       about repair work that software development doesn't always provide. The feedback loop is immediate and physical.
       The problem is bounded. The solution is concrete.

       iFixit and Louis Rossmann have done more for right to repair than most legislation.
       """}
    ]
  },
  {
    "chen_wei",
    "Chen Wei",
    "Researcher in computational biology. Interested in the intersection of mathematics, " <>
      "information theory, and living systems.",
    [
      {"science", "What Entropy Actually Means in Biology",
       """
       Entropy is one of the most misused concepts in popular science writing. Let me be precise.

       **Thermodynamic entropy:** A measure of the number of microscopic configurations consistent with a
       macroscopic state. Living systems maintain low entropy locally by exporting entropy to their environment.
       This is not a violation of the second law — it's powered by energy input.

       **Shannon entropy:** A measure of uncertainty or information content in a probability distribution.
       Related to thermodynamic entropy mathematically but conceptually distinct.

       **The confusion:** Popular accounts often conflate these, leading to claims like "life decreases entropy"
       (locally true, globally false).
       """},
      {"mathematics", "Bayesian vs Frequentist: Why the Debate Still Matters",
       """
       The choice between Bayesian and frequentist inference has practical consequences.

       **Frequentist interpretation:** Probability = long-run frequency. P-values and confidence intervals
       are frequentist constructs, widely misinterpreted.

       **Bayesian interpretation:** Probability = degree of belief, updated by evidence. You specify prior
       beliefs and update with data to get posterior beliefs.

       **Why it matters:** Frequentist p-values are widely misinterpreted — a p-value is NOT the probability
       your hypothesis is true. The replication crisis is partly attributable to misuse of frequentist inference.

       Neither framework is universally superior. Understanding both makes you a better analyst.
       """},
      {"mathematics", "The Unreasonable Effectiveness of Linear Algebra",
       """
       Linear algebra shows up everywhere with particular force.

       **In quantum mechanics:** States are vectors, observables are operators.
       **In computer graphics:** Transformations are matrix multiplications.
       **In machine learning:** Neural networks are compositions of affine transformations.
       **In genomics:** PCA reduces 20,000-dimensional gene expression data to interpretable structure.

       The concept of eigenvalues and eigenvectors alone underlies Google's PageRank, principal component
       analysis, and quantum mechanical measurement.
       """},
      {"philosophy", "Scientific Realism vs Anti-Realism: A Practical Difference",
       """
       **Scientific realism:** Successful theories are approximately true descriptions of reality,
       including unobservable entities (dark matter is probably real).

       **Anti-realism/instrumentalism:** Theories are instruments for predicting observations.
       Dark matter is a calculational device that works — but no more.

       **The challenge to realism:** The pessimistic meta-induction — past successful theories were
       later shown to be false or radically revised. Our current theories are probably similarly wrong.

       **Structural realism:** What science gets right is the mathematical structure of the world,
       not necessarily the nature of entities.
       """},
      {"books", "Reading Gödel, Escher, Bach in 2026",
       """
       Hofstadter's *Gödel, Escher, Bach* was published in 1979. Reading it in 2026 is a strange experience.

       **What holds up:** The core argument about self-reference, strange loops, and consciousness is as interesting
       as ever. The treatment of Gödel's incompleteness theorems is among the best accessible presentations I've seen.

       **What dates it:** The AI discussions reflect 1970s AI — LISP programs, rule-based systems.

       **The central question:** Can a formal system be "aware" of itself? We now have systems that produce
       the behavioral signatures of self-awareness without (probably) the phenomenology.
       GEB is worth reading precisely because the question remains unresolved.
       """}
    ]
  },
  {
    "marta_writes",
    "Marta Lindqvist",
    "Writer and editor. Interested in online communities, digital culture, " <>
      "media history, and the occasional philosophy rabbit hole.",
    [
      {"books", "Against Goodreads Ratings",
       """
       Goodreads has reduced literary evaluation to a 5-star rating system, and I think it's made us worse readers.

       **The problem with stars:** They conflate distinct dimensions — personal enjoyment, literary craft,
       accessibility, importance.

       **The aggregation problem:** Averaged across millions of ratings, the books that score highest tend to be:
       broadly accessible (not challenging), in popular genres, part of series (fan bases skew high).

       Moby-Dick averages ~3.5 stars. The Hunger Games averages ~4.3 stars. This is not a meaningful literary judgment.

       I still use Goodreads for the shelving. I've stopped looking at the ratings.
       """},
      {"philosophy", "On Being Wrong and Updating Beliefs",
       """
       I've been wrong about a lot of things I was confident about.

       **What I've learned:**
       1. Confidence is not correlated with accuracy, particularly for complex social phenomena.
       2. The way you hold beliefs matters as much as which beliefs you hold. Bayesian updating —
          treating beliefs as probability estimates — makes revision feel natural rather than defeat.
       3. Public commitment makes updating harder. I try to hedge more and make fewer strong predictions.

       **The useful question:** What evidence would change my mind? If I can't answer, I'm not reasoning —
       I'm rationalizing.
       """},
      {"history", "The History of the Editorial Letter",
       """
       The editorial letter — the feedback document editors send to authors during manuscript development —
       has a surprisingly interesting history that mirrors the history of publishing.

       Maxwell Perkins at Scribner's (editor of Hemingway, Fitzgerald, Wolfe) operated largely through
       conversation and marginalia. The sustained editorial letter emerged with the typewriter.

       **What changed:** Email made editorial correspondence faster. Track changes in Word moved some feedback
       to inline notation. The editorial letter in its classic form — a sustained, considered document —
       survives in literary fiction publishing but has largely disappeared in commercial genres.

       The irony: as writing tools have improved, editorial feedback quality has, in many houses, declined.
       """},
      {"meta", "What Good Moderation Looks Like",
       """
       The variable that most reliably predicts community health is moderation quality.

       **Bad moderation:** Reactive, rule-enforcement-focused, inconsistent, explained poorly.
       Bad moderators manage individual incidents; they don't shape community culture.

       **Good moderation:** Proactive, norm-setting, consistent, transparent. Good moderators remove content
       not just for rule violations but because it moves the community away from what it's trying to be.

       **What makes it hard:** Moderators absorb the community's negativity. Burnout is endemic.
       The best communities treat moderation as a collective responsibility, not a delegated task.
       """},
      {"music", "On Silence in Music",
       """
       Miles Davis: "It takes a long time to play like yourself."
       John Cage: "I have nothing to say, and I am saying it."

       **What silence does:** In jazz, space is what makes the notes mean something. A note released early
       creates tension; a note held longer resolves differently. The drummer's rest is as intentional as the hit.

       **Cage's 4'33":** The piece consists of the performer not playing for four minutes and thirty-three seconds.
       The "music" is the ambient sound of the environment. Whether this is profound insight or an elaborate joke
       depends on your theory of music. I think it's both.

       **A practice:** Listen to any piece you know well. This time, follow the rests.
       """}
    ]
  },
  {
    "kaito_tanaka",
    "Kaito Tanaka",
    "Software engineer and independent game developer. " <>
      "Making small games in Godot on weekends. Likes strategy games and retrocomputing.",
    [
      {"gaming", "Why I Make Small Games Instead of Big Ones",
       """
       I've been making games independently for four years. My games are small. Deliberately, obstinately small.

       **The scale trap:** Most aspiring indie developers underestimate scope by a factor of 5–10×.
       The game in your head is always larger than the game you can ship.

       **What small means:** My current project has a 2-hour playthrough, 8 levels, one mechanic.
       This would have seemed inadequate to me four years ago. Now I understand it as ruthless prioritization.

       **The counterintuitive truth:** Small, finished games get played.
       Large, unfinished games don't exist.
       """},
      {"programming", "Godot 4's Type System: What It Gets Right",
       """
       Godot 4 introduced typed GDScript as a first-class feature. After working with it for a year:

       **What changed:** GDScript is now optionally statically typed. Type annotations provide:
       - Dramatically better autocomplete
       - Errors caught before running
       - Self-documenting function signatures

       **What's still missing:** Generics. Collection types (`Array`, `Dictionary`) can be typed
       but not parameterized the way Kotlin or TypeScript generics work.

       **My recommendation:** Use types. The friction of adding type annotations is far lower than
       the friction of debugging type errors in untyped GDScript.
       """},
      {"history", "The History of Arcade Game Design",
       """
       Arcade games were designed under unique constraints that shaped design philosophy in ways
       that still influence games today.

       **The quarter-fed constraint:** Every design decision was filtered through one question:
       will this make the player insert another quarter?

       **Key design patterns:**
       - **Escalating difficulty:** the game never ends because it gets harder, not because you "win"
       - **Spectacle:** attract mode, high score screens — advertising the game while waiting
       - **Short feedback loops:** lives, not health bars; immediate consequence for mistakes

       Pac-Man's ghost behavior is still taught in game design programs because it creates perceived
       intelligence through simple rules.
       """},
      {"technology", "Retrocomputing as a Learning Practice",
       """
       I bought a working Apple IIe last year. This is what I've learned from it.

       **Why retrocomputing:** Modern computers are extraordinarily complex. Retrocomputers have bottoms
       you can touch. On a 6502-based system, you can understand the entire memory map.

       **What you learn:** The path from input to output is short enough to trace completely.
       This gives you a mental model that informs how you think about modern systems.

       **The humbling part:** Game developers shipped playable, beautiful games in 16KB.
       The resource constraint forced creativity in a way that unlimited RAM and cycles don't.
       """},
      {"gaming", "What Tactics Ogre Taught Me About Game Narrative",
       """
       Tactics Ogre: Let Us Cling Together (1995, remade 2022) contains the most sophisticated political
       narrative in any strategy game.

       **What it does differently:** Most games present clear ethical dilemmas. Tactics Ogre presents
       choices that are genuinely ambiguous: both options have defensible justifications and terrible consequences.
       The game doesn't tell you which choice is right.

       **What this teaches game developers:** Player choice is most meaningful when the player cannot
       determine the "correct" answer in advance. The discomfort of making an unjustifiable choice —
       and living with its consequences — creates emotional investment that scripted narrative can't match.

       The game is thirty years old. The lesson remains current.
       """}
    ]
  }
]

Enum.each(users_data, fn {username, display_name, bio, posts} ->
  IO.puts("\n  -- @#{username}")
  user = Seeds.Util.ensure_user(username, display_name, bio)

  Enum.each(posts, fn {board_slug, title, body} ->
    board = Seeds.Util.board!(boards, board_slug)
    Seeds.Util.post_article(user, board, title, body)
  end)
end)

IO.puts("\n==> Seeds complete!")
IO.puts("    Sample users: alice_dev, bob_sysadmin, chen_wei, marta_writes, kaito_tanaka")
IO.puts("    Sample user password: Password123!x")
IO.puts("    (Admin credentials depend on your local setup)")
