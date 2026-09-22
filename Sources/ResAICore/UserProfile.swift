import Foundation

public struct UserProfile: Codable, Equatable {
    public var displayName: String
    public var companyName: String
    public var department: String
    public var role: String
    public var email: String
    public var phone: String
    public var website: String
    public var address: String
    public var socialURL: String
    public var background: String
    public var serviceDescription: String
    public var formFillNotes: String
    public var writingStyle: String
    public var preferredPhrases: String
    public var avoidedPhrases: String

    public init(
        displayName: String = "",
        companyName: String = "",
        department: String = "",
        role: String = "",
        email: String = "",
        phone: String = "",
        website: String = "",
        address: String = "",
        socialURL: String = "",
        background: String = "",
        serviceDescription: String = "",
        formFillNotes: String = "",
        writingStyle: String = "",
        preferredPhrases: String = "",
        avoidedPhrases: String = ""
    ) {
        self.displayName = displayName
        self.companyName = companyName
        self.department = department
        self.role = role
        self.email = email
        self.phone = phone
        self.website = website
        self.address = address
        self.socialURL = socialURL
        self.background = background
        self.serviceDescription = serviceDescription
        self.formFillNotes = formFillNotes
        self.writingStyle = writingStyle
        self.preferredPhrases = preferredPhrases
        self.avoidedPhrases = avoidedPhrases
    }

    public var isEmpty: Bool {
        [
            displayName,
            companyName,
            department,
            role,
            email,
            phone,
            website,
            address,
            socialURL,
            background,
            serviceDescription,
            formFillNotes,
            writingStyle,
            preferredPhrases,
            avoidedPhrases
        ].allSatisfy { normalized($0).isEmpty }
    }

    public static func load(defaults: UserDefaults = .standard) -> UserProfile {
        UserProfile(
            displayName: defaults.string(forKey: DefaultsKey.displayName) ?? "",
            companyName: defaults.string(forKey: DefaultsKey.companyName) ?? "",
            department: defaults.string(forKey: DefaultsKey.department) ?? "",
            role: defaults.string(forKey: DefaultsKey.role) ?? "",
            email: defaults.string(forKey: DefaultsKey.email) ?? "",
            phone: defaults.string(forKey: DefaultsKey.phone) ?? "",
            website: defaults.string(forKey: DefaultsKey.website) ?? "",
            address: defaults.string(forKey: DefaultsKey.address) ?? "",
            socialURL: defaults.string(forKey: DefaultsKey.socialURL) ?? "",
            background: defaults.string(forKey: DefaultsKey.background) ?? "",
            serviceDescription: defaults.string(forKey: DefaultsKey.serviceDescription) ?? "",
            formFillNotes: defaults.string(forKey: DefaultsKey.formFillNotes) ?? "",
            writingStyle: defaults.string(forKey: DefaultsKey.writingStyle) ?? "",
            preferredPhrases: defaults.string(forKey: DefaultsKey.preferredPhrases) ?? "",
            avoidedPhrases: defaults.string(forKey: DefaultsKey.avoidedPhrases) ?? ""
        )
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(displayName, forKey: DefaultsKey.displayName)
        defaults.set(companyName, forKey: DefaultsKey.companyName)
        defaults.set(department, forKey: DefaultsKey.department)
        defaults.set(role, forKey: DefaultsKey.role)
        defaults.set(email, forKey: DefaultsKey.email)
        defaults.set(phone, forKey: DefaultsKey.phone)
        defaults.set(website, forKey: DefaultsKey.website)
        defaults.set(address, forKey: DefaultsKey.address)
        defaults.set(socialURL, forKey: DefaultsKey.socialURL)
        defaults.set(background, forKey: DefaultsKey.background)
        defaults.set(serviceDescription, forKey: DefaultsKey.serviceDescription)
        defaults.set(formFillNotes, forKey: DefaultsKey.formFillNotes)
        defaults.set(writingStyle, forKey: DefaultsKey.writingStyle)
        defaults.set(preferredPhrases, forKey: DefaultsKey.preferredPhrases)
        defaults.set(avoidedPhrases, forKey: DefaultsKey.avoidedPhrases)
    }

    public func promptText(maxFieldCharacters: Int = 420) -> String {
        let fields = [
            ("名前", displayName),
            ("会社・組織", companyName),
            ("部署", department),
            ("役割・肩書き", role),
            ("背景", background),
            ("サービス・事業説明", serviceDescription),
            ("文体", writingStyle),
            ("よく使う言い回し", preferredPhrases),
            ("避けたい言い回し", avoidedPhrases)
        ]

        let lines = fields.compactMap { label, value -> String? in
            let text = normalized(value)
            guard !text.isEmpty else {
                return nil
            }
            return "\(label): \(limited(text, maxCharacters: maxFieldCharacters))"
        }

        return lines.isEmpty ? "(プロフィールなし)" : lines.joined(separator: "\n")
    }

    public func formFillPromptText(maxFieldCharacters: Int = 700) -> String {
        let fields = [
            ("名前", displayName),
            ("会社・組織", companyName),
            ("部署", department),
            ("役割・肩書き", role),
            ("メール", email),
            ("電話", phone),
            ("Webサイト", website),
            ("住所", address),
            ("SNS・プロフィールURL", socialURL),
            ("背景・自己紹介", background),
            ("サービス・事業説明", serviceDescription),
            ("フォーム回答用メモ", formFillNotes)
        ]

        let lines = fields.compactMap { label, value -> String? in
            let text = normalized(value)
            guard !text.isEmpty else {
                return nil
            }
            return "\(label): \(limited(text, maxCharacters: maxFieldCharacters))"
        }

        return lines.isEmpty ? "(プロフィールなし)" : lines.joined(separator: "\n")
    }

    public func localFormFillValue(for label: String) -> String? {
        let text = normalized(label).lowercased()
        guard !text.isEmpty else {
            return nil
        }
        guard !containsAny(text, [
            "password",
            "passcode",
            "security code",
            "verification code",
            "auth code",
            "one-time code",
            "one time code",
            "otp",
            "card",
            "credit",
            "cvc",
            "cvv",
            "agree",
            "consent",
            "terms",
            "privacy policy",
            "パスワード",
            "暗証",
            "認証コード",
            "確認コード",
            "ワンタイム",
            "カード",
            "クレジット",
            "同意",
            "規約",
            "プライバシー"
        ]) else {
            return nil
        }

        let mappings: [(keys: [String], value: String)] = [
            (["email", "e-mail", "e mail", "mail address", "メール", "メールアドレス"], email),
            (["phone", "tel", "mobile", "電話", "携帯"], phone),
            (["company", "organization", "organisation", "会社", "法人", "組織", "団体"], companyName),
            (["department", "division", "部署", "部門"], department),
            (["role", "title", "position", "job", "役職", "肩書", "職種"], role),
            (["name", "full name", "氏名", "名前", "お名前"], displayName),
            (["website", "url", "homepage", "site", "web", "ホームページ", "サイト"], website),
            (["address", "所在地", "住所"], address),
            (["sns", "x ", "twitter", "linkedin", "facebook", "プロフィールurl"], socialURL),
            (["service", "product", "事業", "サービス", "プロダクト"], firstNonEmpty([serviceDescription, background])),
            (["profile", "bio", "自己紹介", "紹介"], firstNonEmpty([background, serviceDescription])),
            (["purpose", "goal", "issue", "challenge", "interest", "目的", "課題", "関心", "興味", "導入", "自由記述", "お問い合わせ"], firstNonEmpty([formFillNotes, serviceDescription, background]))
        ]

        for mapping in mappings where containsAny(text, mapping.keys) {
            let value = normalized(mapping.value)
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case displayName
        case companyName
        case department
        case role
        case email
        case phone
        case website
        case address
        case socialURL
        case background
        case serviceDescription
        case formFillNotes
        case writingStyle
        case preferredPhrases
        case avoidedPhrases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName) ?? "",
            companyName: try container.decodeIfPresent(String.self, forKey: .companyName) ?? "",
            department: try container.decodeIfPresent(String.self, forKey: .department) ?? "",
            role: try container.decodeIfPresent(String.self, forKey: .role) ?? "",
            email: try container.decodeIfPresent(String.self, forKey: .email) ?? "",
            phone: try container.decodeIfPresent(String.self, forKey: .phone) ?? "",
            website: try container.decodeIfPresent(String.self, forKey: .website) ?? "",
            address: try container.decodeIfPresent(String.self, forKey: .address) ?? "",
            socialURL: try container.decodeIfPresent(String.self, forKey: .socialURL) ?? "",
            background: try container.decodeIfPresent(String.self, forKey: .background) ?? "",
            serviceDescription: try container.decodeIfPresent(String.self, forKey: .serviceDescription) ?? "",
            formFillNotes: try container.decodeIfPresent(String.self, forKey: .formFillNotes) ?? "",
            writingStyle: try container.decodeIfPresent(String.self, forKey: .writingStyle) ?? "",
            preferredPhrases: try container.decodeIfPresent(String.self, forKey: .preferredPhrases) ?? "",
            avoidedPhrases: try container.decodeIfPresent(String.self, forKey: .avoidedPhrases) ?? ""
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(companyName, forKey: .companyName)
        try container.encode(department, forKey: .department)
        try container.encode(role, forKey: .role)
        try container.encode(email, forKey: .email)
        try container.encode(phone, forKey: .phone)
        try container.encode(website, forKey: .website)
        try container.encode(address, forKey: .address)
        try container.encode(socialURL, forKey: .socialURL)
        try container.encode(background, forKey: .background)
        try container.encode(serviceDescription, forKey: .serviceDescription)
        try container.encode(formFillNotes, forKey: .formFillNotes)
        try container.encode(writingStyle, forKey: .writingStyle)
        try container.encode(preferredPhrases, forKey: .preferredPhrases)
        try container.encode(avoidedPhrases, forKey: .avoidedPhrases)
    }

    private func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func limited(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else {
            return value
        }

        return String(value.prefix(maxCharacters)) + "..."
    }

    private func containsAny(_ text: String, _ keys: [String]) -> Bool {
        keys.contains { text.contains($0.lowercased()) }
    }

    private func firstNonEmpty(_ values: [String]) -> String {
        values.first { !normalized($0).isEmpty } ?? ""
    }

    public enum DefaultsKey {
        public static let displayName = "profile.displayName"
        public static let companyName = "profile.companyName"
        public static let department = "profile.department"
        public static let role = "profile.role"
        public static let email = "profile.email"
        public static let phone = "profile.phone"
        public static let website = "profile.website"
        public static let address = "profile.address"
        public static let socialURL = "profile.socialURL"
        public static let background = "profile.background"
        public static let serviceDescription = "profile.serviceDescription"
        public static let formFillNotes = "profile.formFillNotes"
        public static let writingStyle = "profile.writingStyle"
        public static let preferredPhrases = "profile.preferredPhrases"
        public static let avoidedPhrases = "profile.avoidedPhrases"
        public static let isEnabled = "profile.isEnabled"
    }
}
