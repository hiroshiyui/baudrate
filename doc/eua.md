<!--
  TEMPLATE. The live agreement lives in the `eua` setting, edited at
  /admin/settings, shown during registration and published at /terms. This
  file is the source to edit and re-paste, and a starting point for anyone
  running their own instance.

  Fill in, in BOTH languages:
    [SITE_NAME]       what the site is called
    [SITE_URL]        its address
    [OPERATOR]        who runs it (a name or an organisation)
    [CONTACT]         how to reach them
    [SOURCE_URL]      where the running source can be obtained (section 3)
    [JURISDICTION]    whose law governs the agreement (section 11)
    [EFFECTIVE DATE]  the date it is published

  [SOURCE_URL] is not decorative. The AGPL requires offering the source of the
  version actually running, so an instance with local modifications must point
  at its own repository, not at upstream.

  The governing language clause names 台灣漢語 as prevailing. Change it, and
  the language halves, if this instance serves a different audience.

  An email in angle brackets — <someone@example.org> — becomes a mailto link
  and survives sanitizing; that form is fine to use.

  When pasting into /admin/settings, start from the "歡迎來到" line and leave
  this comment behind. It is normally stripped when rendered, but a leading
  HTML block can swallow what follows it, so do not rely on that.

  Publishing a materially changed version: tick "require every member to
  accept again" when saving, which bumps `eua_version` and pauses posting for
  everyone until they accept (ADR 0031). Leave it unticked for a typo.

  Checked against the code at v1.21.0. **Re-check when behaviour changes**,
  particularly: the sanction ladder and the guarantee that every sanction is
  notified (ADR 0029), that rules live at /rules and a report can cite one
  (ADR 0032), and that there is still no self-service account deletion (6E).

  Not legal advice. Have someone qualified read it before relying on it.
-->

# 使用者協議 End User Agreement (EUA)

歡迎來到 [[SITE_NAME]]([SITE_URL])。本站由 **[OPERATOR]** 營運。在您註冊或使用本服務前，請仔細閱讀以下條款。
Welcome to [[SITE_NAME]]([SITE_URL]). This site is operated by **[OPERATOR]**. Please read the following terms carefully before registering or using our services.

---

### 語言 Language

本協議同時以台灣漢語與英文提供。**兩者如有歧異，以台灣漢語版本為準。**
This agreement is provided in both 台灣漢語 (Taiwanese Mandarin) and English. **In the event of any discrepancy, the 台灣漢語 version prevails.**

### 1. 接受條款 Acceptance of Terms

當您註冊或使用本網站時，即表示您同意受本協議所有條款的約束。如果您不同意，請立即停止使用本服務。
By registering for or using this website, you agree to be bound by all terms of this agreement. If you do not agree, please stop using the service immediately.

本站會記錄您接受本協議的時間與版本。當本協議有重大變更時，您會看到提示，並且在您重新接受之前，發文與互動會暫停；閱讀不受影響。
This site records when you accepted this agreement and which version. When it changes materially you will be prompted, and posting and interacting are paused until you accept again; reading is unaffected.

### 2. 使用資格 Eligibility

* 本服務不適合未滿 13 歲者使用，亦不應為其註冊帳號。
    This service is not intended for anyone under 13, and no account should be created for one.
* 依本站目前的註冊設定，新帳號可能需要管理者審核，或需要邀請碼才能註冊。
    Depending on this site's current registration setting, a new account may require approval by staff, or an invitation code.
* 機器人帳號僅能由站方建立與管理，且無法登入。
    Bot accounts are created and managed only by site staff, and cannot sign in.

### 3. 開源授權與原始碼 Software License and Source Code

本站點致力於開放原始碼精神：
This platform is committed to the spirit of open source:

* **AGPL-3.0 授權：** 本站點運作所使用的軟體原始碼依據 **GNU AGPL-3.0** 條款授權。
    **AGPL-3.0 License:** The software source code powering this site is licensed under the **GNU AGPL-3.0**.
* **原始碼取得：** 根據 AGPL-3.0 之規定，您可以透過以下連結取得本站點目前運作版本的完整原始碼：`[SOURCE_URL]`。
    **Source Code Availability:** In accordance with the AGPL-3.0, you may obtain the complete source code for the version currently running on this site via: `[SOURCE_URL]`.
* **第三方組件：** 本站可能包含受不同授權條款約束之第三方組件。
    **Third-party Components:** This site may contain third-party components governed by different license terms.

### 4. 帳號與安全 Accounts and Security

* 註冊只需要使用者名稱與密碼；本站不會索取電子郵件或真實姓名。正因如此，**若您同時遺失密碼與救援碼，將無法自行取回帳號**，請妥善保管。
    Registration requires only a username and a password; this site does not ask for an email address or a real name. Because of that, **if you lose both your password and your recovery codes, you cannot recover the account yourself** — keep them safe.
* 您有責任保護自己的帳號安全，並對該帳號下的所有活動負責。請勿與他人共用帳號。
    You are responsible for the security of your account and for all activity under it. Do not share an account with anyone.
* 管理員與版主必須啟用兩階段驗證。一般成員亦建議啟用。
    Administrators and moderators must enable two-factor authentication. Other members are encouraged to.
* 若您發現帳號遭他人存取，請立即變更密碼、登出所有裝置，並聯絡 **[CONTACT]**。
    If you believe someone else has reached your account, change your password, sign out everywhere, and contact **[CONTACT]**.

### 5. 站規 Site Rules

本站的行為準則以 [站規頁面](/rules) 為準，該頁面可能隨時更新。檢舉他人時可以指明所違反的是哪一條站規。
Conduct on this site is governed by the [Rules page](/rules), which may be updated from time to time. When reporting someone, you can point at the specific rule you believe was broken.

無論站規如何規定，下列行為一律禁止：
Regardless of what the rules say, the following are always prohibited:

* 違法、威脅、誹謗、侮辱或侵犯他人隱私之內容。
    Content that is unlawful, threatening, defamatory, abusive, or invasive of privacy.
* 惡意程式碼、病毒，或任何試圖破壞本站運作之行為。
    Malicious code, viruses, or any attempt to disrupt the operation of this site.
* 侵犯他人智慧財產權（如著作權、商標）之內容。
    Content infringing the intellectual property rights of others, such as copyright or trademarks.

### 6. 您的內容、授權與聯邦傳播 Your Content, Licensing, and Federation

* **內容所有權：** 您對自己發布的內容保有所有權，但您授予本站永久、全球性、免權利金的非獨佔使用許可，以便展示、散布該內容，**並透過 ActivityPub 傳送至其他站台**。
    **Ownership:** You retain ownership of the content you post, but you grant this site a perpetual, worldwide, royalty-free, non-exclusive licence to display and distribute it, **including transmitting it to other servers via ActivityPub**.
* **聯邦傳播不可撤回：** 在公開且開啟聯邦功能的看板發文，會將副本送往其他站台，各自保存。在本站刪除只能向對方發出刪除請求，**本站無法保證對方照做**。請在發文前就以「一旦送出即無法收回」的前提考量。
    **Federation cannot be undone:** Posting in a public, federation-enabled board sends copies to other servers, which keep their own. Deleting here only sends them a request; **this site cannot compel them to honour it.** Post on the assumption that what you send cannot be recalled.
* **私訊並非端對端加密：** 送往其他站台的私訊會投遞到該站台，其管理者可以讀取。請視私訊為私人信件，而非機密。
    **Direct messages are not encrypted end to end:** A message to someone on another server is delivered to that server, whose operator can read it. Treat direct messages as private correspondence, not as secret.
* **資料庫與程式碼：** 雖然軟體程式碼依 AGPL 授權開放，但本站之資料庫內容（包含但不限於用戶貼文、圖片、使用者名單）並非 AGPL 授權範圍。
    **Database vs. Code:** While the software code is open-sourced under AGPL, the site's database content (including but not limited to posts, images, and user lists) is not covered by the AGPL licence.

詳細的資料處理方式，請見[隱私權政策](/privacy)。
For how your data is handled in detail, see the [Privacy Policy](/privacy).

### 7. 管理措施 Moderation

違反本協議或站規時，站方可能移除內容，或採取下列措施之一：**警告**、**禁言**（唯讀，可設期限）、**停權**（一段期間內無法登入）、或**永久封鎖**。
If you break this agreement or the rules, staff may remove content or apply one of: a **warning**, a **silence** (read-only, optionally time-limited), a **suspension** (no sign-in until a date), or a **permanent ban**.

**每一項處分都會通知您**，並載明理由與期限；此類通知無法在偏好設定中關閉。內容遭移除時，作者亦會收到通知與理由。
**You are notified of every sanction**, with the reason and how long it lasts; these notices cannot be switched off in preferences. When content is removed, its author is told, with the reason.

即使處於受限狀態，您仍可以閱讀、撤回先前的按讚或轉發、刪除自己的內容、**檢舉濫用行為**，以及進行帳號安全相關操作。
Even while restricted, you may still read, undo an earlier like or boost, delete your own content, **report abuse**, and carry out account-security actions.

### 8. 終止 Termination

* **由您終止：** 本站目前沒有自助刪除帳號的功能，請聯絡 **[CONTACT]** 辦理。您也可以先透過 `/profile` 匯出資料，或將追蹤者遷移至其他站台的帳號。
    **By you:** There is currently no self-service account deletion; contact **[CONTACT]** to arrange it. You may first export your data from `/profile`, or migrate your followers to an account on another server.
* **由站方終止：** 我們保留隨時修改或停止本服務的權利。嚴重或重複違規者，帳號可能被永久封鎖。
    **By us:** We reserve the right to modify or discontinue the service at any time. Accounts may be permanently banned for serious or repeated violations.
* 帳號終止後，已傳送至其他站台的副本不在本站控制範圍內，備份中的資料亦需一段時間才會輪替消失。
    After termination, copies already sent to other servers are outside this site's control, and data in backups takes time to age out.

### 9. 免責聲明 Disclaimer of Warranties

本服務按「現狀」提供，由個人以有限資源營運。我們不保證服務不會中斷、無錯誤或不會遺失資料，亦不對用戶發布內容之準確性負責。
The service is provided "as is", operated by an individual with limited resources. We do not guarantee that it will be uninterrupted, error-free, or free from data loss, nor are we responsible for the accuracy of content posted by users.

### 10. 協議變更 Changes to This Agreement

本協議如有變更，會直接更新本頁並標示新的日期。重大變更會要求所有成員重新接受（見第 1 條）。
Changes to this agreement are published here with a new date. Material changes require every member to accept again (see section 1).

### 11. 法律管轄 Governing Law

本協議受 **[JURISDICTION]** 法律管轄。
This agreement shall be governed by the laws of **[JURISDICTION]**.

---

*最後更新日期：[EFFECTIVE DATE]*
*Last Updated: [EFFECTIVE DATE]*
