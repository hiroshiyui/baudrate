# 隱私權政策 Privacy Policy

<!--
  TEMPLATE. The live policy lives in the `privacy_policy` setting, edited at
  /admin/settings and published at /privacy. This file is the source to edit
  and re-paste, and the starting point for anyone running their own instance.

  Fill in, in BOTH languages:
    [OPERATOR]        who runs the site (a name or an organisation)
    [CONTACT]         how to reach them about personal data
    [EFFECTIVE DATE]  the date it is published

  An email in angle brackets — <someone@example.org> — becomes a mailto link
  and survives sanitizing; that form is fine to use.

  When pasting into /admin/settings, start from the "最後更新" line and leave
  this comment behind. It is normally stripped when rendered, but a leading
  HTML block can swallow what follows it, so do not rely on that.

  Every factual claim was checked against the code at v1.28.0 — the retention
  periods, what federates, what the export omits, and the two third parties a
  visitor's browser can reach. **Re-check them when that behaviour changes**,
  particularly: the YouTube embed auto-loads (4F would add a click-to-play
  gate), uploads are served with no access check, poll votes are attributable
  in the database, and that self-service deletion keeps posts under "deleted
  account" unless the member withdraws them (ADR 0072).

  JURISDICTION: section 6 is not a fill-in-the-blank. It is built on the five
  rights the Taiwan 個人資料保護法 actually grants, so another jurisdiction
  needs that section rewritten, not relabelled — GDPR, for instance, grants
  portability, objection and restriction, which are not listed here. The rest
  of the document describes the software and travels unchanged.

  Not legal advice. Have someone qualified read it against the law that
  applies before relying on it.
-->

**最後更新 Last updated: [EFFECTIVE DATE]**

### 語言 · Language

本政策同時以台灣漢語與英文提供。**兩者如有歧異，以台灣漢語版本為準。**

This policy is provided in both 台灣漢語 (Taiwanese Mandarin) and English.
**In the event of any discrepancy, the 台灣漢語 version prevails.**

---

# 台灣漢語

本站由 **[OPERATOR]** 營運。本頁說明本站會記錄哪些個人資料、為什麼記錄、保存多久，以及您可以提出哪些請求。相關問題請洽 **[CONTACT]**。

本站使用 ActivityPub 與其他站台聯邦互通。**您發表的部分內容會永久離開本伺服器，且無法確實收回**，因此先從這一點說起。

## 一、哪些內容會離開本伺服器

當您在公開且開啟聯邦功能的看板發文，或有其他站台的使用者追蹤您時，本站會將副本送往那些站台。每個站台各自保存自己的副本，並依其自身規則處理。

內容一旦送出：

- **無法確實收回。** 在本站刪除，只是向收到副本的站台發出刪除請求。行為良好的站台會照做，但本站無法強制。若某個站台從未追蹤您、只是自行抓取過該篇內容，可能根本收不到這個請求。
- 其他站台會收到您的**使用者名稱、顯示名稱、自我介紹、頭像、個人檔案連結，以及文章本身**，還有您對這些站台內容所做的按讚、轉發與回覆。
- 文章送出時會一併帶上**原始 Markdown 原文**與排版後的版本，以及該篇累積的按讚數與留言數。
- 這些站台可能位於世界任何地方，由任何人營運。

**任何人都可以讀取您的個人檔案頁面**，不論是否登入，也包含自動化程式：使用者名稱、顯示名稱、自我介紹、頭像與個人檔案連結都會以機器可讀的形式公開，讓其他站台能找到您。這是聯邦運作的方式，但也代表您的個人檔案是最完整意義上的公開。

**私訊在本站是私密的，但並非端對端加密。** 送給其他站台使用者的訊息會投遞到該站台，該站台的管理者可以讀取。本站兩個帳號之間的訊息則不會離開本站。請把私訊當成私人信件看待，而不是機密。

未公開、或未開啟聯邦功能的看板，其內容不會送往其他站台。

## 二、本站會記錄哪些資料

### 您主動提供的

- **帳號**：使用者名稱與密碼。密碼僅以 bcrypt 雜湊儲存。本站沒有電子郵件欄位，不會向您索取。
- **個人檔案**：顯示名稱、自我介紹、簽名檔、頭像、個人檔案欄位與語言偏好。皆為選填，且皆為公開。
- **內容**：文章、留言、回覆、按讚、轉發、書籤、投票，以及您上傳的圖片。
- **私訊**：您收發的訊息，以純文字形式存放於資料庫。
- **兩階段驗證**：若您啟用，會存放 TOTP 金鑰（加密儲存）或已註冊的安全金鑰。

### 您使用本站時自動記錄的

- **您的 IP 位址與瀏覽器識別資訊**，存在兩個地方：您目前的登入工作階段，以及對您帳號的登入嘗試紀錄。您可以在 `/profile/security` 看到自己的工作階段，確認身分後也能看到各工作階段的 IP 位址。
- **您讀過什麼。** 本站會記錄您開啟過哪些文章與看板，以便標示未讀。這是一份附在您帳號上的閱讀紀錄。
- **您編輯過的每一個版本。** 編輯文章時會保留前一版內容與編輯者。舊版本會一直保留，直到該篇文章本身被刪除。
- **是誰邀請您**，以及您邀請了誰。
- **您封鎖或靜音的帳號。**
- **站務紀錄**：您提出的檢舉、針對您的檢舉、對您的帳號或內容採取的措施，以及所記載的理由。
- 所有動作的**時間戳記**。

### 關於投票

投票結果**對其他成員是匿名的**——本站不會向任何人（包含站方）顯示個別成員投給哪一項。但您應該知道：**資料庫會記錄您選擇了哪個選項**，以避免重複投票，並讓您能更改選擇。這不是不記名投票。任何能直接存取資料庫的人都能得知您的選擇。

### 關於上傳的圖片

圖片在存檔前會先解碼再重新編碼，此過程會**清除所有 EXIF 中繼資料，包含手機拍照可能帶有的 GPS 座標**。

但上傳後的圖片是**不經權限檢查**直接提供的：任何取得網址的人都能開啟，不論他能否看到該圖片所屬的文章，也不論該文章是否已被刪除。檔名是很長的隨機十六進位字串，無法猜測——但那是「難以得知」，不是「不得存取」。請不要上傳您不希望被持有連結者看到的圖片。

## 三、Cookie 與瀏覽器儲存

本站只設定**一個 Cookie**：`_baudrate_key`。它存放經簽章與加密的登入工作階段，效期 14 天，標記為 `SameSite=Lax`。沒有它就無法維持登入狀態。它不用於追蹤，也不會分享給任何人。

您的瀏覽器另外會在本機保存一些資料，這些都不會離開您的裝置：您選擇的佈景主題與文字大小，以及——在共用或公用電腦上特別值得注意——**您在發文或留言框中輸入但尚未送出的文字，最長保存 30 天**，以免關閉分頁時遺失。

本站沒有任何流量分析、追蹤像素或廣告。

## 四、與其他公司的關係

**本站刻意避免讓您的瀏覽器連向第三方。** 來自其他站台的圖片——遠端頭像、聯邦附件、轉載文章中的圖片——都由**本伺服器**先取得，再由本站重新提供，因此閱讀聯邦內容不會將您的 IP 位址與閱讀習慣洩漏給內容來源站台。本站的安全性政策也直接封鎖第三方圖片、字型、指令碼與樣式表。

有兩個例外：

- **YouTube。** 當文章中含有 YouTube 影片連結時，頁面會嵌入來自 `youtube-nocookie.com` 的播放器，而且**在您開啟該文章時就會自動載入**。該網域在您按下播放前不會設定追蹤 Cookie，但播放器載入時 Google 仍會取得您的 IP 位址與瀏覽器識別資訊。若您不希望被 Google 看見，請不要開啟顯示 YouTube 播放器的文章。**私訊中同樣適用**：您收到的訊息若含有 YouTube 連結，開啟該對話時就會載入同樣的播放器。訊息內容本身仍然私密，但 Google 會得知有人從您的位址、在何時開啟了含有該影片的頁面。
- **推播通知。** 若您開啟瀏覽器通知，您的瀏覽器會向其廠商的推播服務註冊——依瀏覽器而定為 Google、Mozilla 或 Apple，並非由本站選擇——並提供一個位址讓本站發送。通知內容在交付前**已先加密**，推播服務無法讀取，只有您的裝置能解密。但該服務仍會得知有通知在何時送給您，長期累積可以推測出您的活躍時段。關閉通知即可終止。

當您張貼連結時，是**本伺服器**（而非您的瀏覽器）去抓取該頁面一次以產生預覽卡片。被連結的網站看到的是來自本伺服器的請求，不是來自您。**私訊中的連結同樣會觸發此行為**，因此在訊息中貼上私密或未公開的網址，會導致本伺服器去造訪它。

## 五、保存多久

系統會自動清除：

| 項目 | 期限 |
|------|------|
| 登入嘗試紀錄（含 IP 位址） | 7 天 |
| 過期的登入工作階段（含 IP 與瀏覽器資訊） | 工作階段到期時；自最後使用起 14 天 |
| 通知 | 90 天 |
| 檢舉案中留存的內容副本，以及被檢舉的私訊 | 檢舉結案後 90 天 |
| 待送出的聯邦投遞佇列（內含待投遞的訊息內容） | 已送達 7 天；放棄投遞 30 天 |
| 遠端圖片的本機快取 | 30 天未被存取 |
| 已完成的資料匯出申請 | 365 天 |
| 您刪除的文章與留言，連同其圖片與舊版本 | 刪除後 90 天 |
| 來自您在其他站台追蹤帳號的貼文，若無人按讚、轉發或回覆 | 90 天 |
| 遠端帳號曾轉發某內容的紀錄 | 180 天 |

**在您或站方刪除之前不會自動到期的：**

- 您的帳號與個人檔案；
- 您未刪除的文章與留言；
- 您的私訊——軟刪除會將內容替換為「[deleted]」，但保留寄件者與時間；
- 您的閱讀紀錄；
- 您編輯過的文章的舊版本，保存期限與該文章相同；
- 書籤、按讚、轉發、追蹤、封鎖與靜音；
- 誰邀請了誰的紀錄；
- 您的推播通知註冊資料，直到推播服務拒絕為止。

**設計上永久保存的：**

- **管理日誌與檢舉紀錄**——已採取措施的紀錄與檢舉案，包含檢舉人自行填寫的內容與處理結果；
- **處分紀錄**——警告、禁言或停權只會被解除，不會被抹除，以便站方看見長期的行為樣態。

您刪除的文章或留言會立即隱藏，並於 **90 天後自資料庫移除**，連同其圖片與舊版本。保留這 90 天是為了讓管理者在處理檢舉時仍能看見被移除的內容；若有檢舉案指向該內容，則會保存至該紀錄存續期間。

來自您在其他站台所追蹤帳號的貼文，是他處已發布內容的副本。若本站無人按讚、轉發或回覆，該副本會在 90 天後移除；原始內容仍留在其發布的站台，那不在本站的控制範圍內。

備份每晚執行，伺服器上保存約一週，異地副本保存約一個月，因此**您刪除的資料仍可能在備份中存續約一個月**才會輪替消失。備份僅供災難復原之用，不會被檢索或另作他用。

伺服器日誌會在登入相關路徑記錄 IP 位址。日誌隨磁碟空間輪替，沒有固定的保存期限。

## 六、您的權利

依《個人資料保護法》，您得就本站保有您的個人資料行使下列權利：

1. **查詢或請求閱覽。**
2. **請求製給複製本。**
3. **請求補充或更正。**
4. **請求停止蒐集、處理或利用。**
5. **請求刪除。**

在本站的具體行使方式：

- **立即取得複製本：** 於 `/profile/account` →「匯出您的資料」可產生一份壓縮檔，包含您的個人檔案、文章、留言、回覆、互動、關係、您自己的私訊與邀請碼。此功能要求已啟用兩階段驗證滿七天，因為這份壓縮檔包含關於您的一切，不能讓被竊取的登入狀態就能取走。
- **更正：** 直接編輯您的個人檔案與文章。
- **搬家：** 於 `/profile/account` →「帳號遷移」可將您的追蹤者導向其他站台的帳號。
- **匯出檔未包含的部分**——您的登入紀錄與 IP 位址、通知、檢舉、管理日誌、閱讀紀錄與推播註冊資料。請洽 **[CONTACT]** 索取。
- **刪除：** 於 `/profile/account` →「刪除您的帳號」自行辦理，需再次輸入密碼。刪除會在 7 天後執行，期間重新登入即可取消。您的個人檔案、登入方式、工作階段、草稿與私訊內容都會移除；帳號名稱會保留，不再開放註冊。您的文章與留言預設會保留並顯示為「已刪除的帳號」，您也可以選擇一併撤回。其他站台會收到帳號已刪除的通知，多數站台會隨之移除它們持有的副本，但本站無法強制（見第一節）；備份亦需約一個月才會輪替消失（見第五節）。

若某項紀錄是維持站台安全所必需——例如一筆停權及其理由——縱使您請求刪除，仍可能予以保留，以免相同問題再度發生。

## 七、資料如何受到保護

- 本站僅以 HTTPS 提供服務。
- 密碼以 bcrypt 雜湊儲存；工作階段權杖以雜湊形式儲存；兩階段驗證金鑰與聯邦簽章私鑰以 AES-256-GCM 加密儲存。
- 管理員與版主必須啟用兩階段驗證，進入管理頁面另須再次驗證。
- 變更密碼或第二重驗證因素時，必須再次證明身分，並會發出無法關閉的通知。
- 備份僅限必要帳號可讀；異地副本採「拉取」方式，本伺服器不持有任何足以觸及或刪除這些副本的憑證。

私訊、檢舉、自我介紹與管理日誌在資料庫中以一般文字儲存，靠存取控制保護，而非加密。

沒有任何系統是絕對安全的。若您認為帳號遭他人存取，請立即變更密碼、於 `/profile/security` 登出所有裝置，並聯絡 **[CONTACT]**。

## 八、兒童

本站不適合未滿 13 歲的兒童使用，亦不應為其註冊帳號。

## 九、本政策的變更

本政策若有變更，會直接更新本頁並標示新的日期；重大變更會另行於站上公告。以本頁公布的版本為現行有效版本。

---

# English

This site is run by **[OPERATOR]**. This page explains what personal data the
site records, why, how long it is kept, and what you can ask for. Questions go
to **[CONTACT]**.

This site federates using ActivityPub. **Some of what you post leaves this
server permanently and cannot be recalled**, so that comes first.

## 1. What leaves this server

When you post in a board that is public and federation-enabled, or when someone
on another server follows you, this site sends copies to those servers. Each
keeps its own copy under its own rules.

Once a post has been sent:

- **It cannot be recalled.** Deleting it here sends a request to the servers
  that received it. Well-behaved servers comply. This site cannot make them,
  and a server that fetched the post without ever following you may never get
  the request at all.
- Other servers receive your **username, display name, biography, avatar,
  profile links and the posts themselves**, along with your likes, boosts and
  replies to content from those servers.
- The post travels with its **original Markdown** as well as the formatted
  version, and with counts of the likes and comments it has attracted.
- Those servers may be anywhere in the world, run by anyone.

**Your profile page is readable by anyone, signed in or not**, including
automated clients: username, display name, biography, avatar and profile links
are published in a machine-readable form so other servers can find you. That is
how federation works, but it means your profile is public in the fullest sense.

**Direct messages are private on this site, but they are not encrypted end to
end.** A message to someone on another server is delivered to that server,
whose operator can read it. A message between two accounts here stays here.
Treat direct messages as private correspondence, not as secret.

Content in boards that are not public, or not federation-enabled, is not sent
to other servers.

## 2. What this site records

### What you give it

- **Account**: username and password. The password is stored only as a bcrypt
  hash. There is no email address field — this site does not ask for one.
- **Profile**: display name, biography, signature, avatar, profile fields and
  language preference. All optional, all public.
- **Content**: articles, comments, replies, likes, boosts, bookmarks, poll
  votes, the boards and threads you watch, and any images you upload.
- **Direct messages** you send and receive, stored as plain text in the
  database, and any images attached to them. Those images are shown only to
  the two people in the conversation (and to a moderator if one of you
  reports that message), and are never sent to another server.
- **Two-factor authentication**, if you enable it: a TOTP secret (encrypted at
  rest) or a registered security key.

### What it records as you use the site

- **Your IP address and browser identification**, in two places: your active
  sessions, and the record of sign-in attempts to your account. You can see your
  own sessions at `/profile/security`, and their addresses once you have
  confirmed your identity there.
- **What you have read.** The site records which articles and boards you have
  opened, so it can show you what is new. This is a reading history attached to
  your account.
- **Every version of a post you edit.** Editing keeps the previous version,
  along with who made the edit. Earlier drafts survive the edit and are removed
  only when the post itself is deleted.
- **Who invited you**, and who you have invited.
- **Accounts you block or mute.**
- **Moderation records**: reports you file or that are filed about you, actions
  taken about your account or content, and the reasons given.
- **Timestamps** on everything.

### Poll votes

Poll votes are **anonymous to other members** — the site never shows anyone,
including staff, how an individual voted. But you should know that **the
database records which option you chose**, so that you cannot vote twice and so
that you can change your vote. It is not a secret ballot. Anyone with direct
access to the database could determine how you voted.

### Uploads

Images are decoded and re-encoded before storage, which **destroys all EXIF
metadata, including any GPS coordinates** from a phone camera.

Uploaded images are then served **without any access check**: anyone with the
URL can open them, whether or not they can see the post they belong to, and
whether or not the post has since been deleted. Filenames are long random hex
strings, so they cannot be guessed — but that is obscurity, not permission.
Do not post an image you would not want seen by someone holding its link.

## 3. Cookies and local storage

This site sets **one cookie**, `_baudrate_key`. It carries your signed and
encrypted session, lasts 14 days, and is marked `SameSite=Lax`. Without it you
cannot stay signed in. It is not used for tracking and is shared with nobody.

Your browser also keeps things locally, which never leave your device: your
chosen theme and text size, and — worth knowing on a shared or public computer
— **anything you typed into a post or comment box but did not send, kept for up
to 30 days** so a closed tab does not lose your writing.

There is no analytics, no tracking pixel and no advertising on this site.

## 4. Other companies

**This site deliberately keeps your browser away from third parties.** Images
from other servers — remote avatars, federated attachments, images inside
syndicated articles — are fetched by *this server* and re-served from here, so
reading federated content does not disclose your IP address or reading habits
to the servers that content came from. The site's security policy blocks
third-party images, fonts, scripts and stylesheets outright.

Two exceptions:

- **YouTube.** When a post links to a YouTube video, the page embeds a player
  from `youtube-nocookie.com`, and **it loads as soon as you open the post**.
  That domain sets no tracking cookies before you press play, but Google
  receives your IP address and browser identification when the player loads. If
  you would rather Google did not see you, do not open posts showing a YouTube
  player. **This applies inside direct messages as well:** a YouTube link in a
  message you receive loads the same player when you open the conversation.
  The message itself stays private, but Google learns that someone at your
  address opened a page containing that video, and when.
- **Push notifications.** If you turn on browser notifications, your browser
  registers with its own vendor's push service — Google, Mozilla or Apple,
  depending on your browser, not chosen by this site — and gives this site an
  address to send to. Notifications are **encrypted before they are handed
  over**, so the push service cannot read them; only your device can. It does
  learn that a notification was sent to you and when, which over time reveals
  when you are active. A notification about a direct message says only who
  it is from — never what it says, because your device may show it on the
  lock screen. Turning notifications off ends this.

When you post a link, this server — not your browser — fetches the page once to
build a preview. The linked site sees a request from this server, not from you.
**This happens for links in direct messages too**, so pasting a private or
unlisted URL into a message causes this server to visit it.

## 5. How long things are kept

Cleared automatically:

| What | After |
|------|-------|
| Sign-in attempts, with their IP addresses | 7 days |
| Expired sessions, with their IP and browser | at session expiry; 14 days from last use |
| Notifications | 90 days |
| Content copied into a report as evidence, and any reported direct message | 90 days after the report is closed |
| Queued federation deliveries, which contain the message being delivered | 7 days delivered, 30 days abandoned |
| Cached copies of remote images | 30 days untouched |
| Completed data export requests | 365 days |
| Posts and comments you deleted, and their images and earlier versions | 90 days after deletion |
| Posts from accounts you follow elsewhere, if nobody liked, boosted or replied to them | 90 days |
| The record that a remote account shared something | 180 days |

**Kept until you or staff remove them, with no automatic expiry:**

- your account and profile;
- posts and comments you have not deleted;
- your direct messages — soft deletion replaces the text with "[deleted]" but
  keeps the sender and the timestamp;
- your reading history;
- earlier versions of posts you have edited, for as long as the post itself;
- bookmarks, watched boards and threads, likes, boosts, follows, blocks and
  mutes;
- the record of who invited whom;
- your push notification registrations, until the push service rejects them.

**Kept permanently, by design:**

- **moderation records** — the log of actions taken, and reports, including the
  reporter's own words and the outcome;
- **sanctions** — a warning, silence or suspension is lifted, never erased, so
  that a pattern remains visible to staff.

A post or comment you delete is hidden at once and **removed from the database
90 days later**, together with its images and its earlier versions. The 90 days
exist so that a moderator handling a report can still see what was removed; if
a report refers to it, it is kept for as long as that record.

Posts that reach you from accounts you follow on other servers are a copy of
something published elsewhere. That copy is removed after 90 days unless
somebody here liked, boosted or replied to it — the original stays wherever it
was posted, which is not something this site controls.

Backups run nightly, are kept about a week on the server and about a month
off-site, so **data you delete can survive in backups for roughly a month**
before ageing out. Backups exist for disaster recovery and are not searched or
used for anything else.

Server logs record IP addresses on sign-in paths. They rotate as the disk fills
and are not kept to any fixed schedule.

## 6. Your rights

Under the Personal Data Protection Act (個人資料保護法), you may ask to:

1. **Know and review** the personal data held about you.
2. **Receive a copy** of it.
3. **Have it corrected or completed.**
4. **Stop its collection, processing or use.**
5. **Have it deleted.**

How to exercise them here:

- **A copy, straight away:** `/profile/account` → Export my data produces an archive of
  your profile, posts, comments, replies, interactions, relationships, your own
  direct messages and your invites. It requires two-factor authentication
  enabled for at least seven days, because the archive is everything about you
  in one file and a stolen session must not be able to take it.
- **Correction:** edit your profile and your posts directly.
- **Moving on:** `/profile/account` → Move account redirects your followers elsewhere.
- **What the export does not include** — your sign-in history and IP addresses,
  notifications, reports, the moderation log, your reading history, and push
  registrations. Ask **[CONTACT]** and they will be provided.
- **Deletion:** `/profile/account` → Delete your account, after entering your
  password again. It happens seven days later, and signing in before then
  cancels it. Your profile, sign-in methods, sessions, drafts and the text of
  your direct messages are removed; your username is kept so nobody else can
  take it. Your posts and comments stay, shown as "deleted account", unless you
  choose to withdraw them too. Other servers are told the account is gone, and
  most remove the copies they hold, but this site cannot make them (section 1);
  backups age out over about a month (section 5).

Where a record is needed to keep the site safe — a ban and its reason, for
instance — it may be kept despite a deletion request, so that the same problem
does not simply return.

## 7. How your data is protected

- The site is served only over HTTPS.
- Passwords are bcrypt hashes; session tokens are stored hashed; two-factor
  secrets and federation signing keys are encrypted at rest with AES-256-GCM.
- Administrators and moderators must use two-factor authentication, and
  administrative pages require re-verification.
- Changing your password or your second factor requires proving who you are
  again, and sends a notice that cannot be switched off.
- Backups are readable only by the accounts that need them, and off-site copies
  are pulled — this server holds no credential that could reach or delete them.

Direct messages, reports, biographies and moderation records are stored as
ordinary text in the database. They are protected by access control, not by
encryption.

No system is perfectly secure. If you think someone else has reached your
account, change your password, sign out everywhere from `/profile/security`, and write
to **[CONTACT]**.

## 8. Children

This site is not intended for children under 13, and no account should be
created for one.

## 9. Changes to this policy

Changes appear here with a new date at the top, and material changes are
announced on the site. The version in force is the one published on this page.
