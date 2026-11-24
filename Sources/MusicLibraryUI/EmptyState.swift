import SwiftUI

/// What a page shows when it has nothing to show: the app's take on `ContentUnavailableView`, with the same
/// initializers, so it drops in for it. The symbol is brass, the title is set in poster capitals, the description in the
/// reading serif.
public struct EmptyState<LabelContent: View, Description: View, Actions: View>: View {
    let label: LabelContent
    let description: Description
    let actions: Actions

    public init(@ViewBuilder label: () -> LabelContent, @ViewBuilder description: () -> Description,
                @ViewBuilder actions: () -> Actions) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    #if os(macOS)
    static var titleSize: CGFloat { 30 }
    static var textSize: CGFloat { 15 }
    #else
    static var titleSize: CGFloat { 28 }
    static var textSize: CGFloat { 16 }
    #endif

    public var body: some View {
        VStack(spacing: 14) {
            label.labelStyle(EmptyStateLabelStyle(titleSize: Self.titleSize))
            description
                .font(AppFont.serif(Self.textSize))
                .foregroundStyle(AppColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) { actions }
                .padding(.top, 4)
        }
        .frame(maxWidth: 440)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Description == EmptyView, Actions == EmptyView {
    public init(@ViewBuilder label: () -> LabelContent) {
        self.init(label: label, description: { EmptyView() }, actions: { EmptyView() })
    }
}

extension EmptyState where Actions == EmptyView {
    public init(@ViewBuilder label: () -> LabelContent, @ViewBuilder description: () -> Description) {
        self.init(label: label, description: description, actions: { EmptyView() })
    }
}

extension EmptyState where Description == EmptyView {
    public init(@ViewBuilder label: () -> LabelContent, @ViewBuilder actions: () -> Actions) {
        self.init(label: label, description: { EmptyView() }, actions: actions)
    }
}

extension EmptyState where LabelContent == Label<Text, Image>, Description == Text?, Actions == EmptyView {
    public init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil) {
        self.init(label: { Label(title, systemImage: systemImage) }, description: { description }, actions: { EmptyView() })
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, systemImage: String, description: Text? = nil) {
        self.init(label: { Label(title, systemImage: systemImage) }, description: { description }, actions: { EmptyView() })
    }

    /// A search that found nothing.
    public static func search(text: String) -> Self {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(trimmed.isEmpty ? "No Results" : "No Results for “\(trimmed)”", systemImage: "magnifyingglass",
                    description: Text("Check the spelling or try a new search."))
    }

    /// A search that found nothing.
    public static var search: Self { search(text: "") }
}

/// The empty state's label: the symbol large and light in brass over the title in condensed capitals.
struct EmptyStateLabelStyle: LabelStyle {
    let titleSize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 12) {
            configuration.icon
                .font(.system(size: titleSize * 1.4, weight: .light))
                .foregroundStyle(AppColor.accent)
                .symbolRenderingMode(.hierarchical)
            configuration.title
                .font(AppFont.display(titleSize, weight: .heavy))
                .textCase(.uppercase)
                .foregroundStyle(AppColor.text)
                .multilineTextAlignment(.center)
        }
    }
}
