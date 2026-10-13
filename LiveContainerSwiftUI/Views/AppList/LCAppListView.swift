//
//  ContentView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers
import Intents

private func scheduleGridDragCleanup(draggingApp: Binding<LCAppModel?>, cleanupID: Binding<UUID>, delay: TimeInterval = 0.7) {
    let newID = UUID()
    cleanupID.wrappedValue = newID
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        if cleanupID.wrappedValue == newID {
            draggingApp.wrappedValue = nil
        }
    }
}

private func cancelGridDrag(draggingApp: Binding<LCAppModel?>, cleanupID: Binding<UUID>) {
    cleanupID.wrappedValue = UUID()
    draggingApp.wrappedValue = nil
}

private struct LCGridAppFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, newValue in newValue }
    }
}

private struct LCGridDropDelegate: DropDelegate {
    let apps: [LCAppModel]
    let appFrames: [String: CGRect]
    @Binding var draggingApp: LCAppModel?
    @Binding var dragCleanupID: UUID
    @ObservedObject var sortManager: LCAppSortManager
    
    func performDrop(info: DropInfo) -> Bool {
        cancelGridDrag(draggingApp: $draggingApp, cleanupID: $dragCleanupID)
        return true
    }
    
    func dropExited(info: DropInfo) {
        cancelGridDrag(draggingApp: $draggingApp, cleanupID: $dragCleanupID)
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        moveDraggingApp(to: info.location)
        scheduleGridDragCleanup(draggingApp: $draggingApp, cleanupID: $dragCleanupID)
        return DropProposal(operation: .move)
    }
    
    private func moveDraggingApp(to location: CGPoint) {
        guard let draggingApp else { return }
        let destinationIndex = gridDestinationIndex(for: location)
        withAnimation(.easeInOut(duration: 0.18)) {
            sortManager.moveCustomSortApp(draggingApp, toDestinationIndex: destinationIndex, in: apps, visibleApps: DataManager.shared.model.apps, hiddenApps: DataManager.shared.model.hiddenApps)
        }
    }
    
    private func gridDestinationIndex(for location: CGPoint) -> Int {
        let indexedFrames = apps.enumerated().compactMap { index, app -> (index: Int, frame: CGRect)? in
            guard let uniqueIdentifier = sortManager.getUniqueIdentifier(for: app),
                  let frame = appFrames[uniqueIdentifier] else { return nil }
            return (index, frame)
        }
        
        guard !indexedFrames.isEmpty else { return apps.count }
        
        if let lowestFrame = indexedFrames.map(\.frame).max(by: { $0.maxY < $1.maxY }),
           location.y > lowestFrame.maxY {
            return apps.count
        }
        
        let closestRowMidY = indexedFrames
            .min(by: { abs($0.frame.midY - location.y) < abs($1.frame.midY - location.y) })?
            .frame.midY ?? 0
        
        let rowFrames = indexedFrames
            .filter { abs($0.frame.midY - closestRowMidY) < ($0.frame.height / 2) }
            .sorted { $0.frame.minX < $1.frame.minX }
        
        for indexedFrame in rowFrames {
            if location.x < indexedFrame.frame.midX {
                return indexedFrame.index
            }
        }
        
        return (rowFrames.last?.index ?? apps.count - 1) + 1
    }
}

class SearchContext: ObservableObject {
    @Published var query: String = ""
    @Published var debouncedQuery: String = ""
    @Published var isTyping: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        $query
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isTyping = true
                self?.debouncedQuery = value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.isTyping = false
                }
            }
            .store(in: &cancellables)
    }
}

struct AppReplaceOption : Hashable {
    var isReplace: Bool
    var nameOfFolderToInstall: String
    var appToReplace: LCAppModel?
}

/// Dedicated view that observes LCAppModel so @Published isSigningInProgress
/// and signProgress changes cause re-renders even when called from a non-observed context.
struct AppSigningProgressBar: View {
    @ObservedObject var model: LCAppModel

    var body: some View {
        // Wrap in a zero-height container when not signing so the VStack
        // collapse animation pushes the banner back up cleanly.
        VStack(spacing: 0) {
            if model.isSigningInProgress {
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 6)
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: max(0, geo.size.width * CGFloat(model.signProgress)), height: 6)
                                .animation(.linear(duration: 0.15), value: model.signProgress)
                        }
                    }
                    .frame(height: 6)
                    Text(model.signProgress < 0.05 ? "Preparing…"
                         : model.signProgress >= 0.99 ? "Finishing…"
                         : "Installing \(Int(model.signProgress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.isSigningInProgress)
    }
}

// Split into two views, each always present as its own ToolbarItem (see call
// site), rather than one view whose *number* of children varies (1 in
// multiselect, 1 or 2 otherwise depending on platform/state). Keeping the
// item count constant and branching only on each item's own internal content
// is the same pattern that fixed analogous toolbar flakiness in the Updates
// tab — varying how many children a single ToolbarItemGroup's content
// produces from one render to the next is apparently still enough to make
// SwiftUI's toolbar reconciliation drop content on iPad, even when each
// individual branch's view type is otherwise stable.
private struct AppListSearchToolbarButton: View {
    let show: Bool
    @Binding var isSearchPresented: Bool
    var body: some View {
        if show {
            Button {
                isSearchPresented = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
        } else {
            EmptyView()
        }
    }
}

private struct AppListSecondaryToolbarButton: View {
    let isMultiSelectMode: Bool
    let isDeleting: Bool
    let selectedAppsForDeletion: Set<LCAppModel>
    let installprogressVisible: Bool
    let sideStoreExists: Bool
    let darkModeIcon: Bool
    let onIgnoreSelected: () -> Void
    let onUnignoreSelected: () -> Void
    let onOpenSideStore: () -> Void
    let onHelp: () -> Void

    // Self-contained rather than plumbed up as a parent-owned Binding —
    // this button never needs to be told to show its own dialog from
    // outside, so there's no reason to make the parent view own this state.
    @State private var showOptions = false

    var body: some View {
        if isMultiSelectMode {
            // Pressable before selecting anything, same as Trash/Lock — but
            // unlike those, this doesn't arm/change any selection mode
            // first. It just applies to whatever's currently selected,
            // silently doing nothing if that's empty (the functions below
            // already guard on an empty selection).
            //
            // A plain Button + .confirmationDialog here (not a Menu) —
            // mirrors the same pattern the Trash button above already uses
            // successfully for its own delete confirmation. A Menu embedded
            // directly as toolbar content was what made this slot vanish
            // after being dismissed, even just from opening it and tapping
            // outside without picking either option.
            Button {
                showOptions = true
            } label: {
                Image(systemName: "bell.slash")
                    .foregroundColor(selectedAppsForDeletion.isEmpty ? .secondary : .primary)
            }
            .disabled(isDeleting)
            .confirmationDialog(
                "lc.tabView.updates".loc,
                isPresented: $showOptions,
                titleVisibility: .visible
            ) {
                Button("lc.appList.ignoreUpdatesSelected".loc) {
                    onIgnoreSelected()
                }
                Button("lc.appList.unignoreUpdatesSelected".loc) {
                    onUnignoreSelected()
                }
                Button("lc.common.cancel".loc, role: .cancel) {}
            }
        } else if installprogressVisible {
            ProgressView().progressViewStyle(.circular).padding(.horizontal, 8)
        } else if sideStoreExists {
            Button(action: onOpenSideStore) {
                IconImageView(icon: BuiltInSideStoreAppInfo.shared.iconIsDarkIcon(darkModeIcon))
                    .frame(width: UIFont.preferredFont(forTextStyle: .body).lineHeight,
                           height: UIFont.preferredFont(forTextStyle: .body).lineHeight)
            }
        } else {
            Button("Help", systemImage: "questionmark", action: onHelp)
        }
    }
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    @State var didAppear = false
    // ipa choosing stuff
    @State var choosingIPA = false
    @State var errorShow = false
    @State var errorInfo = ""
    
    // ipa installing stuff
    @State var installprogressVisible = false
    @State var installProgressPercentage : Float = 0.0
    @State var installObserver : NSKeyValueObservation?
    
    @State var installOptions: [AppReplaceOption]
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    @State private var generatedIconStyleHasCustom = false
    @State private var generatedIconStyleShowVariants = false
    
    @State var safariViewOpened = false
    @State var safariViewURL = URL(string: "https://google.com")!
    @State private var didRunAutoCleanOnStartup = false
    
    @State private var navigateTo : AnyView?
    @State private var isNavigationActive = false
    
    @State private var helpPresent = false
    
    @State private var customSortViewPresent = false
    @State private var draggingApp: LCAppModel?
    @State private var dragCleanupID = UUID()
    @State private var visibleGridAppFrames: [String: CGRect] = [:]
    @State private var hiddenGridAppFrames: [String: CGRect] = [:]
    
    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("LCLaunchInMultitaskMode") var launchInMultitaskMode = false
    @AppStorage("LCAppListInterfaceStyle", store: LCUtils.appGroupUserDefault) var appListInterfaceStyle: LCAppListInterfaceStyle = .list
    @AppStorage("LCAppGridShowLabels", store: LCUtils.appGroupUserDefault) var appGridShowLabels = false
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    
    @State private var isViewAppeared = false
    
    @ObservedObject var searchContext: SearchContext
    @State private var isSearchPresented = false
    private var downloadHelper: DownloadHelper { sharedModel.downloadHelper }

    
    // Multi-select: apps are selected once (freely, regardless of which action
    // you intend), then Delete or Lock/Hide act directly on that selection.
    // The one exception is the "delete data" toggle: it stays disabled until
    // the trash button has been pressed once to arm delete intent, so it can't
    // be flipped while e.g. only intending to lock/hide.
    @State private var isMultiSelectMode = false
    @State private var selectedAppsForDeletion: Set<LCAppModel> = []
    @State private var isDeleting = false
    @State private var isDeleteArmed = false
    @State private var isLockArmed = false
    @State private var deleteAppData = false
    @State private var deleteConfirmDialogPresented = false
    @StateObject private var lockHideActionAlert = AlertHelper<String>()
    @StateObject private var unhideActionAlert = AlertHelper<String>()
    @State private var isDrainingInstallQueue = false

    var sortedApps: [LCAppModel] {
        return sharedAppSortManager.sortedApps
    }
    
    var sortedHiddenApps: [LCAppModel] {
        return sharedAppSortManager.sortedHiddenApps
    }
    
    var filteredApps: [LCAppModel] {
        let apps = sortedApps
        if searchContext.debouncedQuery.isEmpty {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    var filteredHiddenApps: [LCAppModel] {
        let apps = sortedHiddenApps
        if searchContext.debouncedQuery.isEmpty || !sharedModel.isHiddenAppUnlocked {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }

    /// Compares two semantic version strings (e.g. "1.2.3").
    /// Returns true if `sourceVersion` is newer than `installedVersion`.
    static func isSourceVersionNewer(_ sourceVersion: String, than installedVersion: String) -> Bool {
        let sourceComponents = sourceVersion.split(separator: ".").compactMap { Int($0) }
        let installedComponents = installedVersion.split(separator: ".").compactMap { Int($0) }
        let maxLength = max(sourceComponents.count, installedComponents.count)
        for i in 0..<maxLength {
            let s = i < sourceComponents.count ? sourceComponents[i] : 0
            let installed = i < installedComponents.count ? installedComponents[i] : 0
            if s != installed { return s > installed }
        }
        return false
    }

    /// Searches all loaded sources and returns the newest available version
    /// for the given bundle ID that is newer than `installedVersion`.
    /// When the same app appears in multiple sources, the overall newest wins.
    static func bestUpdateVersion(
        for bundleId: String,
        installedVersion: String,
        installedName: String? = nil,
        sources: [AltStoreSourcesViewModel.SourceItem]
    ) -> AltStoreSourceAppVersion? {
        var best: AltStoreSourceAppVersion? = nil
        for item in sources {
            guard let source = item.source else { continue }
            guard let sourceApp = source.apps.first(where: { $0.bundleIdentifier == bundleId }) else { continue }
            // Name check: if the installed app name is known, require source name to match
            // (ignoring spaces) to avoid cross-fork updates (e.g. modded → different mod).
            if let installedName {
                let normalize: (String) -> String = { $0.filter { !$0.isWhitespace }.lowercased() }
                guard normalize(sourceApp.name) == normalize(installedName) else { continue }
            }
            // Prefer the versions array (sorted newest-first); fall back to latestVersion for legacy sources
            let candidates = sourceApp.versions.isEmpty
                ? [sourceApp.latestVersion].compactMap { $0 }
                : sourceApp.versions
            for candidate in candidates {
                guard isSourceVersionNewer(candidate.version, than: installedVersion) else { continue }
                if let current = best {
                    if isSourceVersionNewer(candidate.version, than: current.version) {
                        best = candidate
                    }
                } else {
                    best = candidate
                }
                break // versions are sorted newest-first; first valid one is the best from this source
            }
        }
        return best
    }

    private func updateAction(for app: LCAppModel) -> (() -> Void)? {
        guard let bundleId = app.appInfo.bundleIdentifier(),
              let installedVersion = app.appInfo.version() else { return nil }
        guard let updateVersion = Self.bestUpdateVersion(
            for: bundleId,
            installedVersion: installedVersion,
            installedName: app.appInfo.displayName(),
            sources: sharedModel.sourcesViewModel.sources
        ) else { return nil }
        let downloadURL = updateVersion.downloadURL
        return {
            // Stay on current tab — redirect will happen after download completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Find the source app to get its icon URL
                let sourceIconURL: URL? = DataManager.shared.model.sourcesViewModel.sources
                    .compactMap { $0.source }
                    .flatMap { $0.apps }
                    .first { $0.bundleIdentifier == app.appInfo.bundleIdentifier() }?
                    .iconURL
                NotificationCenter.default.post(
                    name: NSNotification.InstallAppNotification,
                    object: [
                        "url": downloadURL,
                        "appName": app.appInfo.displayName() as Any,
                        "isUpdate": true,
                        "iconURL": sourceIconURL as Any
                    ]
                )
            }
        }
    }

    init(searchContext: SearchContext) {
        self.searchContext = searchContext
        _installOptions = State(initialValue: [])
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
        NavigationView {
            ScrollView {
                NavigationLink(
                    destination: navigateTo,
                    isActive: Binding(
                        get: { isNavigationActive && !isMultiSelectMode },
                        set: { newValue in
                            if !newValue && isNavigationActive {
                                // User tapped back — run the full close sequence
                                // so the navigation state resets cleanly
                                closeNavigationView()
                            } else {
                                isNavigationActive = newValue
                            }
                        }
                    ),
                    label: { EmptyView() }
                )
                .hidden()
                .disabled(isMultiSelectMode)
                
                appList(apps: filteredApps, hidden: false, gridID: "apps")
                    .padding()
                    .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredApps)

                VStack {
                    if sharedModel.hiddenApps.count > 0 {
                        VStack(spacing: 8) {
                            HStack {
                                Text("lc.appList.hiddenApps".loc)
                                    .font(.system(.title2).bold())
                                Spacer()
                            }
                            appList(apps: filteredHiddenApps, hidden: !sharedModel.isHiddenAppUnlocked, gridID: "hiddenApps")
                            .animation(.easeInOut, value: sharedModel.isHiddenAppUnlocked)
                            .onTapGesture {
                                // Previously this was suppressed any time isMultiSelectMode was
                                // true, which meant if hidden apps weren't unlocked yet when you
                                // entered multiselect, there was no way to reveal them at all —
                                // you'd have to exit, authenticate, then re-enter. Only suppress
                                // it once already unlocked, so it doesn't fight with tapping rows
                                // to select them, but always allow the initial reveal.
                                if !sharedModel.isHiddenAppUnlocked || !isMultiSelectMode {
                                    Task { await authenticateUser() }
                                }
                            }
                        }
                        .padding()
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                    }

                    let appCount = sharedModel.isHiddenAppUnlocked ? filteredApps.count + filteredHiddenApps.count : filteredApps.count
                    Text(appCount > 0 || searchContext.debouncedQuery != "" ? "lc.appList.appCounter %lld".localizeWithFormat(appCount) : (sharedModel.multiLCStatus == 2 ? "lc.appList.convertToSharedToShowInLC2".loc : "lc.appList.installTip".loc))
                        .padding(.horizontal)
                        .foregroundStyle(.gray)
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: appCount)
                        .onTapGesture(count: 3) {
                            Task { await authenticateUser() }
                        }
                }.animation(searchContext.isTyping ? nil : .easeInOut, value: sharedModel.hiddenApps.count)

                if sharedModel.multiLCStatus == 2 {
                    Text("lc.appList.manageInPrimaryTip".loc).foregroundStyle(.gray).padding()
                }

            }
            .navigationBarProgressBar(show:$installprogressVisible, progress: $installProgressPercentage)
            .coordinateSpace(name: "scroll")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Reserve space so app banners aren't hidden behind the download tray
                if sharedModel.multiLCStatus != 2 && !isMultiSelectMode {
                    Color.clear.frame(height: 80)
                }
            }
            .onAppear {
                if !didAppear {
                    onAppear()
                }
            }
            
            .navigationTitle("lc.appList.myApps".loc)
            .toolbar {
                // Leading: search / spinner / SideStore / Help — the second
                // slot swaps to bulk ignore/unignore updates during
                // multiselect, in the same place the SideStore button (or
                // spinner/Help, whichever would show) normally occupies.
                //
                // Two separate, always-present ToolbarItems (never a single
                // item whose branch produces a varying number of children)
                // — see AppListSearchToolbarButton/AppListSecondaryToolbarButton
                // above for why that's what actually fixed this slot
                // intermittently vanishing on iPad.
                ToolbarItem(placement: .topBarLeading) {
                    AppListSearchToolbarButton(
                        show: !isMultiSelectMode && SharedModel.isPhone,
                        isSearchPresented: $isSearchPresented
                    )
                }
                ToolbarItem(placement: .topBarLeading) {
                    AppListSecondaryToolbarButton(
                        isMultiSelectMode: isMultiSelectMode,
                        isDeleting: isDeleting,
                        selectedAppsForDeletion: selectedAppsForDeletion,
                        installprogressVisible: installprogressVisible,
                        sideStoreExists: UserDefaults.sideStoreExist(),
                        darkModeIcon: darkModeIcon,
                        onIgnoreSelected: ignoreUpdatesForSelectedApps,
                        onUnignoreSelected: unignoreUpdatesForSelectedApps,
                        onOpenSideStore: { LCUtils.openSideStore(delegate: self) },
                        onHelp: { helpPresent = true }
                    )
                }
                // Trailing: swaps between normal and multiselect content
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isMultiSelectMode {
                        // Delete-data toggle: only meaningful once delete intent is
                        // armed (trash pressed once), so it's disabled until then.
                        Button {
                            withAnimation { deleteAppData.toggle() }
                        } label: {
                            Image(systemName: deleteAppData ? "externaldrive.fill.badge.minus" : "externaldrive.badge.minus")
                                .foregroundColor(!isDeleteArmed ? .secondary : (deleteAppData ? .red : .primary))
                        }
                        .disabled(isDeleting || !isDeleteArmed)

                        // Trash: first press arms delete intent (enables the data
                        // toggle above); second press with apps selected confirms;
                        // second press with nothing selected disarms again. Can't
                        // be armed while Lock/Hide is armed — the two are mutually
                        // exclusive so you can't multi-lock and multi-delete at once.
                        Button {
                            withAnimation {
                                if !isDeleteArmed {
                                    isDeleteArmed = true
                                    isLockArmed = false
                                } else if selectedAppsForDeletion.isEmpty {
                                    isDeleteArmed = false
                                    deleteAppData = false
                                } else {
                                    deleteConfirmDialogPresented = true
                                }
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(isDeleteArmed ? .red : .secondary)
                        }
                        .disabled(isDeleting || isLockArmed)
                        .confirmationDialog(
                            "lc.appList.deleteSelectedConfirm".loc,
                            isPresented: $deleteConfirmDialogPresented,
                            titleVisibility: .visible
                        ) {
                            Button("lc.common.delete".loc, role: .destructive) {
                                Task { await deleteSelectedApps() }
                            }
                            Button("lc.common.cancel".loc, role: .cancel) {}
                        } message: {
                            Text("lc.appList.deleteSelectedMessage %lld".localizeWithFormat(selectedAppsForDeletion.count))
                        }

                        // Lock & Hide / Unlock & Unhide: same arm-then-act pattern as
                        // Trash, so it's pressable before selecting anything too.
                        // Can't be armed while delete is armed (mutually exclusive).
                        Button {
                            withAnimation {
                                if !isLockArmed {
                                    isLockArmed = true
                                    isDeleteArmed = false
                                    deleteAppData = false
                                } else if selectedAppsForDeletion.isEmpty {
                                    isLockArmed = false
                                } else {
                                    Task { await toggleLockHideSelectedApps() }
                                }
                            }
                        } label: {
                            Image(systemName: "lock.shield.fill")
                                .foregroundColor(isLockArmed ? .orange : .secondary)
                        }
                        .disabled(isDeleting || isDeleteArmed)

                        // Cancel multiselect
                        Button {
                            withAnimation {
                                isMultiSelectMode = false
                                selectedAppsForDeletion.removeAll()
                                deleteAppData = false
                                isDeleteArmed = false
                                isLockArmed = false
                            }
                            sharedModel.isMultiSelectMode = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .disabled(isDeleting)
                    } else {
                        Button("lc.appList.openLink".loc, systemImage: "link") {
                            Task { await onOpenWebViewTapped() }
                        }
                        Menu {
                            Picker("Sort by", selection: $sharedAppSortManager.appSortType) {
                                ForEach(AppSortType.allCases, id: \.self) { sortType in
                                    Label(sortType.displayName, systemImage: sortType.systemImage)
                                        .tag(sortType)
                                }
                            }
                            .onChange(of: sharedAppSortManager.appSortType) { newValue in
                                if sharedAppSortManager.appSortType == .custom && appListInterfaceStyle != .grid {
                                    customSortViewPresent = true
                                }
                            }
                            if sharedAppSortManager.appSortType == .custom && appListInterfaceStyle != .grid {
                                Divider()
                                Button {
                                    customSortViewPresent = true
                                } label: {
                                    Label("lc.appList.sort.customManage".loc, systemImage: "slider.horizontal.3")
                                }
                            }
                        } label: {
                            Label("Sort by", systemImage: "line.3.horizontal.decrease.circle")
                        }
                        Button {
                            withAnimation { isMultiSelectMode = true }
                            sharedModel.isMultiSelectMode = true
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(.green)
                                .font(.system(size: 18, weight: .semibold))
                        }
                    }
                }
                // Bottom bar: multiselect actions — 3 buttons, always tappable
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())

        // ── Persistent download/install tray (hidden during multiselect) ──
        if sharedModel.multiLCStatus != 2 && !isMultiSelectMode {
            DownloadTrayView(
                manager: sharedModel.downloadHelper,
                onInstallIPA: { choosingIPA = true },
                onInstallURL: { Task { await startInstallFromUrl() } }
            )
        }

        } // end ZStack
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            Task { await startInstallApp(fileUrls[0]) }
        }, onDismiss: {
            choosingIPA = false
        })
        .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
            ForEach(installOptions, id: \.self) { installOption in
                Button(role: installOption.isReplace ? .destructive : nil, action: {
                    installReplaceAlert.close(result: installOption)
                }, label: {
                    Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                })
            
            }
            Button(role: .cancel, action: {
                installReplaceAlert.close(result: nil)
            }, label: {
                Text("lc.appList.abortInstallation".loc)
            })
        } message: {
            Text("lc.appList.installReplaceTip".loc)
        }
        .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
            Button(role: .destructive) {
                runWhenMultitaskAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                runWhenMultitaskAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmRunWhenMultitasking".loc)
        }
        .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented:$generatedIconStyleSelector.show) {
            Button {
                generatedIconStyleSelector.close(result: .Light)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.light".loc)
            }
            if generatedIconStyleShowVariants {
                Button {
                    generatedIconStyleSelector.close(result: .Dark)
                } label: {
                    Text("lc.appList.generatedIconStyleSelector.dark".loc)
                }
                Button {
                    generatedIconStyleSelector.close(result: .Original)
                } label: {
                    Text("lc.appList.generatedIconStyleSelector.original".loc)
                }
            }
            if generatedIconStyleHasCustom {
                Button {
                    generatedIconStyleSelector.close(result: .Custom)
                } label: {
                    Text("lc.appList.generatedIconStyleSelector.custom".loc)
                }
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                generatedIconStyleSelector.close(result: nil)
            }
        }
        // Lock options alert — for visible apps
        .alert("Lock / Hide Apps", isPresented: $lockHideActionAlert.show) {
            Button(role: .destructive) { lockHideActionAlert.close(result: "lockAndHide") } label: {
                Text("Lock & Hide")
            }
            Button { lockHideActionAlert.close(result: "lockOnly") } label: {
                Text("Lock Only")
            }
            Button("lc.common.cancel".loc, role: .cancel) { lockHideActionAlert.close(result: nil) }
        } message: {
            Text("Choose what to do with the selected \(selectedAppsForDeletion.filter { !$0.appInfo.isHidden }.count) app(s).")
        }
        // Unhide options alert — for hidden apps
        .alert("Unhide / Unlock Apps", isPresented: $unhideActionAlert.show) {
            Button(role: .destructive) { unhideActionAlert.close(result: "unlockAndUnhide") } label: {
                Text("Unlock & Unhide")
            }
            Button { unhideActionAlert.close(result: "unhideOnly") } label: {
                Text("Unhide Only")
            }
            Button("lc.common.cancel".loc, role: .cancel) { unhideActionAlert.close(result: nil) }
        } message: {
            Text("Choose what to do with the selected \(selectedAppsForDeletion.filter { $0.appInfo.isHidden }.count) hidden app(s).")
        }

        .textFieldAlert(
            isPresented: $webViewUrlInput.show,
            title:  "lc.appList.enterUrlTip".loc,
            text: $webViewUrlInput.initVal,
            placeholder: "scheme://",
            action: { newText in
                webViewUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                webViewUrlInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title:  "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in
                installUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                installUrlInput.close(result: nil)
            }
        )
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            JITEnablingModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installFromPlist(urlStr: urlStr)
            })
        }
        .fullScreenCover(isPresented: $safariViewOpened) {
            SafariView(url: $safariViewURL)
        }
        .sheet(isPresented: $helpPresent) {
            LCHelpView(isPresent: $helpPresent)
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView()
        }
        .onAppear() {
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                
                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .apps, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onDrop(of: [.url], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url else { return }
                Task {
                    guard let urlToOpen = await webViewUrlInput.open(initVal: url.absoluteString), urlToOpen != "" else {
                        return
                    }
                    await openWebView(urlString: urlToOpen)
                }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                let name = obj2["appName"] as? String ?? ""
                let iconURL = obj2["iconURL"] as? URL
                let isUpdateFlag = (obj2["isUpdate"] as? Bool) == true
                let entry = SharedModel.PendingInstall(url: installUrl, isUpdate: isUpdateFlag, appName: name, iconURL: iconURL)
                sharedModel.pendingInstallQueue.append(entry)
            }
        }
        // Drain the legacy bulk-install queue (Update All path).
        .onReceive(sharedModel.$pendingInstallURLs) { urls in
            guard !urls.isEmpty else { return }
            Task { await drainInstallQueue() }
        }
        // Drain the structured install queue — processes each entry fully before next.
        .onReceive(sharedModel.$pendingInstallQueue) { queue in
            guard !queue.isEmpty else { return }
            Task { await drainPendingInstallQueue() }
        }
        .apply {
            if #available(iOS 17.0, *) {
                $0.searchable(text: $searchContext.query, isPresented: $isSearchPresented)
            } else {
                $0.searchable(text: $searchContext.query)
            }
        }

    }
    
    var JITEnablingModal : some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .padding(.vertical)
                        .id(0)
                    
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .onAppear {
                    proxy.scrollTo(0)
                }
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc, role: .cancel) {
                        jitAlert.close(result: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        jitAlert.close(result: true)
                    } label: {
                        Text("lc.appBanner.jitLaunchNow".loc)
                    }
                }
            }
        }
    }
    
    func onOpenWebViewTapped() async {
        guard let urlToOpen = await webViewUrlInput.open(), urlToOpen != "" else {
            return
        }
        await openWebView(urlString: urlToOpen)
        
    }
    func onAppear() {
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
        Task {
            await autoCleanEnabledAppsOnStartup()
        }
        didAppear = true
    }
    
    func autoCleanEnabledAppsOnStartup() async {
        if didRunAutoCleanOnStartup {
            return
        }
        didRunAutoCleanOnStartup = true
        
        let appsToConsider = sharedModel.apps + sharedModel.hiddenApps
        for app in appsToConsider {
            if !app.uiAutoCleanCacheOnLaunch {
                continue
            }
            guard let bundlePath = app.appInfo.bundlePath() else {
                continue
            }
            
            let containerTargets = app.uiContainers.map { container in
                LCAppContainerTarget(url: container.containerURL, needsSecurityScope: container.storageBookMark != nil)
            }
            
            do {
                let cleanupResult = try await Task.detached(priority: .utility) {
                    try lcClearAppCacheAndTemp(bundlePath: bundlePath, containerTargets: containerTargets)
                }.value
                
                app.appInfo.clearIconCache()
                app.appInfo.recordAutoClean(withBytesSaved: cleanupResult.removedBytes)
                app.objectWillChange.send()
            } catch {
                NSLog("[LC] auto-clean failed for %@: %@", app.displayName, error.localizedDescription)
            }
        }
    }
    
    
    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: urlString)
            return
        }
        
        if urlToOpen.scheme != "https" && urlToOpen.scheme != "http" {
            var appToLaunch : LCAppModel? = nil
            var appListsToConsider = [sharedModel.apps]
            if sharedModel.isHiddenAppUnlocked {
                appListsToConsider.append(sharedModel.hiddenApps)
            }
            appLoop:
            for appList in appListsToConsider {
                for app in appList {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
            }


            guard let appToLaunch = appToLaunch else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
                errorShow = true
                return
            }
            
            if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            
            do {
                try await appToLaunch.runApp(urlStr: urlToOpen.url!.absoluteString)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            return
        }
        webViewURL = urlToOpen.url!
        if webViewOpened {
            webViewOpened = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                webViewOpened = true
            })
        } else {
            webViewOpened = true
        }
    }


    
    func startInstallApp(_ fileUrl:URL) async {
        do {
            self.installprogressVisible = true
            try await installIpaFile(fileUrl)
            try FileManager.default.removeItem(at: fileUrl)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            self.installprogressVisible = false
        }
    }
    
    nonisolated func decompress(_ path: String, _ destination: String ,_ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }
    
    func installIpaFile(_ url:URL, wasUpdate: Bool = false) async throws {
        let fm = FileManager()
        
        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        self.installProgressPercentage = 0.0
        self.installObserver = installProgress.observe(\.fractionCompleted) { p, v in
            DispatchQueue.main.async {
                self.installProgressPercentage = Float(p.fractionCompleted)
            }
        }
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 80)
        let payloadPath = fm.temporaryDirectory.appendingPathComponent("Payload")
        if fm.fileExists(atPath: payloadPath.path) {
            try fm.removeItem(at: payloadPath)
        }
        
        // decompress
        guard await decompress(url.path, fm.temporaryDirectory.path, decompressProgress) == 0 else {
            throw "lc.appList.urlFileIsNotIpaError".loc
        }

        let payloadContents = try fm.contentsOfDirectory(atPath: payloadPath.path)
        var appBundleName : String? = nil
        for fileName in payloadContents {
            if fileName.hasSuffix(".app") {
                appBundleName = fileName
                break
            }
        }
        guard let appBundleName = appBundleName else {
            throw "lc.appList.bundleNotFondError".loc
        }

        let appFolderPath = payloadPath.appendingPathComponent(appBundleName)
        
        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        // ── Update validation ─────────────────────────────────────────────────
        // If this install was triggered from the Updates tab (wasUpdate == true),
        // verify the extracted IPA's bundle ID matches an installed app. If it does
        // NOT match, the user is downloading a fresh app (not an update). We cancel
        // the install and surface an alert directing them to the Apps tab.
        if wasUpdate, let downloadedBundleId = newAppInfo.bundleIdentifier() {
            let allApps = sharedModel.apps + sharedModel.hiddenApps
            if let reason = LCUpdatesValidator.validateIfMarkedAsUpdate(
                downloadedBundleId: downloadedBundleId,
                allApps: allApps
            ) {
                // Clean up extracted payload
                try? fm.removeItem(at: payloadPath)
                self.installprogressVisible = false
                throw reason
            }
        }
        // ─────────────────────────────────────────────────────────────────────

        var appRelativePath = "\(newAppInfo.bundleIdentifier()!.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace : LCAppModel? = nil
        // Folder exist! show alert for user to choose which bundle to replace
        var sameBundleIdApp = sharedModel.apps.filter { app in
            return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
        }
        if sameBundleIdApp.count == 0 {
            sameBundleIdApp = sharedModel.hiddenApps.filter { app in
                return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
            }
            
            // we found a hidden app, we need to authenticate before proceeding
            if sameBundleIdApp.count > 0 && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        self.installprogressVisible = false
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    self.installprogressVisible = false
                    return
                }
            }
            
        }
        
        if fm.fileExists(atPath: outputFolder.path) || sameBundleIdApp.count > 0 {
            appRelativePath = "\(newAppInfo.bundleIdentifier()!)_\(Int(CFAbsoluteTimeGetCurrent())).app"

            // When this is an update (triggered from the Updates tab), automatically
            // replace the first matching installed app without showing the dialog.
            // This mirrors how a normal app-store update works — the user already
            // confirmed the update by tapping "Update" on the Updates tab.
            if wasUpdate, let existingApp = sameBundleIdApp.first {
                let replaceOption = AppReplaceOption(
                    isReplace: true,
                    nameOfFolderToInstall: existingApp.appInfo.relativeBundlePath,
                    appToReplace: existingApp
                )
                if existingApp.uiIsShared {
                    outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(replaceOption.nameOfFolderToInstall)
                } else {
                    outputFolder = LCPath.bundlePath.appendingPathComponent(replaceOption.nameOfFolderToInstall)
                }
                appRelativePath = replaceOption.nameOfFolderToInstall
                appToReplace = existingApp
                try fm.removeItem(at: outputFolder)
            } else {
                self.installOptions = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: appRelativePath)]
                
                for app in sameBundleIdApp {
                    self.installOptions.append(AppReplaceOption(isReplace: true, nameOfFolderToInstall: app.appInfo.relativeBundlePath, appToReplace: app))
                }

                guard let installOptionChosen = await installReplaceAlert.open() else {
                    // user cancelled
                    self.installprogressVisible = false
                    try fm.removeItem(at: payloadPath)
                    return
                }
                
                if let appToReplace = installOptionChosen.appToReplace, appToReplace.uiIsShared {
                    outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
                } else {
                    outputFolder = LCPath.bundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
                }
                appRelativePath = installOptionChosen.nameOfFolderToInstall
                appToReplace = installOptionChosen.appToReplace
                if installOptionChosen.isReplace {
                    try fm.removeItem(at: outputFolder)
                }
            }
        }

        // If updating an existing app: show progress bar on its banner.
        // Set synchronously on main actor so the UI updates before file move.
        if let appToReplace {
            await MainActor.run {
                appToReplace.isSigningInProgress = true
                appToReplace.signProgress = 0.0
                self.installprogressVisible = false
            }
            // Feed installProgress percentage into the app model's signProgress
            let observer = installProgress.observe(\.fractionCompleted) { p, _ in
                DispatchQueue.main.async {
                    appToReplace.signProgress = p.fractionCompleted
                }
            }
            _ = observer // retain
        }

        // Move it!
        try fm.moveItem(at: appFolderPath, to: outputFolder)
        let finalNewApp = LCAppInfo(bundlePath: outputFolder.path)
        finalNewApp?.relativeBundlePath = appRelativePath
        
        guard let finalNewApp else {
            errorInfo = "lc.appList.appInfoInitError".loc
            errorShow = true
            return
        }
        
        // patch and sign it
        var signError : String? = nil
        var signSuccess = false
        await withUnsafeContinuation({ c in
            if appToReplace?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                finalNewApp.dontSign = true
            }
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                c.resume()
            }, progressHandler: { signProgress in
                installProgress.addChild(signProgress!, withPendingUnitCount: 20)
            }, forceSign: false)
        })
        
        // we leave it unsigned even if signing failed
        if let signError {
            if signSuccess {
                errorInfo = "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)"
            } else {
                errorInfo = signError.loc
            }
            errorShow = true
        }
        
        if let appToReplace {
            // copy previous configration to new app
            finalNewApp.autoSaveDisabled = true
            finalNewApp.isLocked = appToReplace.appInfo.isLocked
            finalNewApp.isHidden = appToReplace.appInfo.isHidden
            finalNewApp.isJITNeeded = appToReplace.appInfo.isJITNeeded
            finalNewApp.isShared = appToReplace.appInfo.isShared
            finalNewApp.spoofSDKVersion = appToReplace.appInfo.spoofSDKVersion
            finalNewApp.doSymlinkInbox = appToReplace.appInfo.doSymlinkInbox
            finalNewApp.containerInfo = appToReplace.appInfo.containerInfo
            finalNewApp.tweakFolder = appToReplace.appInfo.tweakFolder
            finalNewApp.selectedLanguage = appToReplace.appInfo.selectedLanguage
            finalNewApp.dataUUID = appToReplace.appInfo.dataUUID
            finalNewApp.orientationLock = appToReplace.appInfo.orientationLock
            finalNewApp.dontInjectTweakLoader = appToReplace.appInfo.dontInjectTweakLoader
            finalNewApp.hideLiveContainer = appToReplace.appInfo.hideLiveContainer
            finalNewApp.dontLoadTweakLoader = appToReplace.appInfo.dontLoadTweakLoader
            finalNewApp.doUseLCBundleId = appToReplace.appInfo.doUseLCBundleId
            finalNewApp.fixFilePickerNew = appToReplace.appInfo.fixFilePickerNew
            finalNewApp.fixLocalNotification = appToReplace.appInfo.fixLocalNotification
            finalNewApp.lastLaunched = appToReplace.appInfo.lastLaunched
            finalNewApp.jitLaunchScriptJs = appToReplace.appInfo.jitLaunchScriptJs
            finalNewApp.multitaskSpecified = appToReplace.appInfo.multitaskSpecified
            finalNewApp.classicMode = appToReplace.appInfo.classicMode
            finalNewApp.autoSaveDisabled = false
            finalNewApp.save()
        } else {
            // enable SDK version spoof by default
            finalNewApp.spoofSDKVersion = true
            // Set TweakLoader defaults for new apps (disable by default for security)
            finalNewApp.dontInjectTweakLoader = true
            finalNewApp.dontLoadTweakLoader = true
        }
        finalNewApp.installationDate = Date.now
        
        DispatchQueue.main.async {
            if let appToReplace {
                // Clear per-app progress state before swapping the model out
                appToReplace.isSigningInProgress = false
                appToReplace.signProgress = 0.0

                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                if appToReplace.uiIsHidden {
                    sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                    sharedModel.hiddenApps.append(newAppModel)
                } else {
                    sharedModel.apps.removeAll { $0 == appToReplace }
                    sharedModel.apps.append(newAppModel)
                }
            } else {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                sharedModel.apps.append(newAppModel)
            }
            self.sharedModel.syncSharedGuestURLIndex()
            self.installprogressVisible = false
        }
    }
    
    func startInstallFromUrl() async {
        guard let installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        if let url = URL(string:installUrlStr), url.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: installUrlStr)
            return
        }
        await installFromUrl(urlStr: installUrlStr)
    }
    
    func installFromPlist(urlStr: String) async {
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                errorInfo = "lc.appList.plistInvalidError".loc
                errorShow = true
                return
            }
        }
        
        guard let plistUrl = URL(string: plistUrlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                errorInfo = "lc.appList.plistParseError".loc
                errorShow = true
                return
            }
            
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            
            guard let ipaUrlStr else {
                errorInfo = "lc.appList.plistNoIpaError".loc
                errorShow = true
                return
            }
            
            await installFromUrl(urlStr: ipaUrlStr)
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func installFromUrl(urlStr: String, isUpdate: Bool = false) async {
        // ignore any install request if we are installing another app
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        guard var installUrl = URL(string: urlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        // Don't set installprogressVisible yet — the download phase shows progress
        // via the persistent DownloadTrayView overlay. installprogressVisible (the nav bar
        // spinner + progress bar) only activates during the install/sign phase inside
        // installIpaFile. This way the tray is visible during download.
        defer {
            self.installprogressVisible = false
        }
        
        if installUrl.isFileURL {
            // install from local, we directly call local install method
            let fileExtension = installUrl.pathExtension.lowercased()
            if fileExtension != "ipa" && fileExtension != "tipa" {
                errorInfo = "lc.appList.urlFileIsNotIpaError".loc
                errorShow = true
                return
            }
            
            let fm = FileManager.default
            var didStartAccessing = false
            if !fm.isReadableFile(atPath: installUrl.path),
               let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
                do {
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    installUrl = resolvedURL
                    didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                } catch {
                    errorInfo =  "Failed to resolve shared IPA bookmark: \(error.localizedDescription)"
                    errorShow = true
                    return
                }
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                errorInfo = "lc.appList.ipaAccessError".loc
                errorShow = true
                return
            }
            
            defer {
                if didStartAccessing {
                    installUrl.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                try await installIpaFile(installUrl)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            do {
                // delete ipa if it's in inbox
                var shouldDelete = false
                if let documentsDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let inboxURL = documentsDirectory.appendingPathComponent("Inbox")
                    shouldDelete = installUrl.deletingLastPathComponent().standardizedFileURL == inboxURL.standardizedFileURL
                }
                if shouldDelete {
                    try fm.removeItem(at: installUrl)
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return
        }
        
        do {
            let fileManager = FileManager.default
            // Use a unique filename to prevent collisions between concurrent downloads
            let ext = installUrl.pathExtension.isEmpty ? "ipa" : installUrl.pathExtension
            let destinationURL = fileManager.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)

            // Build a display name for the tray.
            // If a caller pre-set _pendingLegacyName (e.g. sources view set appName,
            // updates view set displayName), consume it; otherwise derive from URL.
            let presetName = downloadHelper._pendingLegacyName
            let rawName    = installUrl.lastPathComponent
            let displayName = !presetName.isEmpty ? presetName
                : (rawName.hasSuffix(".ipa")  ? String(rawName.dropLast(4))
                :  rawName.hasSuffix(".tipa") ? String(rawName.dropLast(5))
                :  rawName)
            downloadHelper._pendingLegacyName = ""

            // Use the isUpdate parameter passed directly — more reliable than shared state
            let wasUpdate = isUpdate || downloadHelper.isUpdate
            downloadHelper.isUpdate = false

            // Consume pending icon URL now (before enqueue clears it) so the
            // icon is reliably attached to the item regardless of thread timing.
            let pendingIcon = downloadHelper._pendingIconURL
            downloadHelper._pendingIconURL = nil

            let item = DownloadItem(
                url: installUrl,
                destinationURL: destinationURL,
                appName: displayName,
                iconURL: pendingIcon,
                isUpdate: wasUpdate
            )
            let itemID = downloadHelper.enqueue(item: item)

            // Phase 1: wait until the item appears in the queue AND is marked active.
            // _start sets isActive via DispatchQueue.main.async, so we must poll.
            var becameActive = false
            for _ in 0..<100 { // up to 5 seconds
                try? await Task.sleep(nanoseconds: 50_000_000)
                if downloadHelper.items.contains(where: { $0.id == itemID && $0.isActive }) {
                    becameActive = true
                    break
                }
                // Also bail early if it was cancelled before becoming active
                if downloadHelper.items.first(where: { $0.id == itemID })?.isCancelled == true {
                    return
                }
            }
            guard becameActive else { return } // timed out — bail silently

            // Phase 2: wait until download finishes (item no longer active)
            while downloadHelper.items.contains(where: { $0.id == itemID && $0.isActive }) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            // Bail silently if cancelled
            guard !(downloadHelper.items.first(where: { $0.id == itemID })?.isCancelled ?? false)
            else { return }

            // Verify the downloaded file actually exists before proceeding
            guard fileManager.fileExists(atPath: destinationURL.path) else {
                errorInfo = "Download completed but file not found at destination."
                errorShow = true
                return
            }

            // Download done — start install/sign phase.
            // Switch to apps tab so the per-app sign progress bar is visible.
            await MainActor.run {
                withAnimation { DataManager.shared.model.selectedTab = .apps }
            }
            self.installprogressVisible = true
            self.installProgressPercentage = 0.0
            try await installIpaFile(destinationURL, wasUpdate: wasUpdate)
            try? fileManager.removeItem(at: destinationURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }
            self.sharedModel.syncSharedGuestURLIndex()
        }
    }
    
    func changeAppVisibility(app: LCAppModel) {
        DispatchQueue.main.async {
            if app.appInfo.isHidden {
                sharedModel.apps.removeAll { now in
                    return app == now
                }
                if !sharedModel.hiddenApps.contains(app) {
                    sharedModel.hiddenApps.append(app)
                }
            } else {
                sharedModel.hiddenApps.removeAll { now in
                    return app == now
                }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
            }

            self.sharedModel.syncSharedGuestURLIndex()
        }
    }

    func appLaunchAvailabilityDidChange() {
        DispatchQueue.main.async {
            self.sharedModel.syncSharedGuestURLIndex()
        }
    }
    
    func launchAppWithBundleId(bundleId : String, container : String?, openURL: String? = nil, forceJIT: Bool? = nil) async {
        if bundleId == "" {
            return
        }
        var appFound : LCAppModel? = nil
        var isFoundAppLocked = false
        for app in sharedModel.apps {
            if app.appInfo.relativeBundlePath == bundleId {
                appFound = app
                if app.appInfo.isLocked {
                    isFoundAppLocked = true
                }
                break
            }
        }
        if appFound == nil {
            for app in sharedModel.hiddenApps {
                if app.appInfo.relativeBundlePath == bundleId {
                    appFound = app
                    isFoundAppLocked = true
                    break
                }
            }
        }
        
        if appFound == nil && bundleId == "builtinSideStore" {
            appFound = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared)
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        guard let appFound else {
            errorInfo = "lc.appList.appNotFoundError".loc
            errorShow = true
            return
        }

        let targetContainer = container ?? appFound.uiDefaultDataFolder
        if let openURL,
           let targetContainer,
           var runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: targetContainer) {
            runningLC = (runningLC as NSString).deletingPathExtension
            let encodedOpenURL = Data(openURL.utf8).base64EncodedString()
            var components = URLComponents()
            components.scheme = runningLC
            components.host = "livecontainer-launch"
            components.queryItems = [
                URLQueryItem(name: "bundle-name", value: bundleId),
                URLQueryItem(name: "container-folder-name", value: targetContainer),
                URLQueryItem(name: "open-url", value: encodedOpenURL)
            ]
            if let forceJIT {
                components.queryItems?.append(URLQueryItem(name: "jit", value: forceJIT ? "true" : "false"))
            }
            if let urlToOpen = components.url, UIApplication.shared.canOpenURL(urlToOpen) {
                await UIApplication.shared.open(urlToOpen)
                return
            }
        }

        if let openURL {
            UserDefaults.standard.setValue(openURL, forKey: "launchAppUrlScheme")
        }

        
        let targetDataUUID = container ?? appFound.appInfo.dataUUID ?? ""


        //⭐️⭐️⭐️switch mode
    if launchInMultitaskMode {
        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, urlStr: openURL, forceJIT: forceJIT)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    } else {
        do {
            try await appFound.runApp(containerFolderName: container, urlStr: openURL, forceJIT: forceJIT)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
}
    
    func authenticateUser() async {
        do {
            if !(try await LCUtils.authenticateUser()) {
                return
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func jitLaunch(appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        await MainActor.run {
            jitLog = ""
        }
        let enableJITTask = Task {

            let _ = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
                Task { await MainActor.run {
                    self.jitLog += "\(newMsg)\n"
                }}
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        guard let result = await jitAlert.open(), result else {
            UserDefaults.standard.removeObject(forKey: "selected")
            enableJITTask.cancel()
            return
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)

    }
    
    private func multitaskPIDJITBundleId(for appToLaunch: LCAppModel) -> String {
        appToLaunch.appInfo.relativeBundlePath ?? appToLaunch.bundleIdentifier
    }

    private func targetGuestBundleIdForPIDJIT() -> String {
        if let selectedBundlePath = UserDefaults.standard.string(forKey: "selected") {
            let appListsToConsider: [[LCAppModel]] = [sharedModel.apps, sharedModel.hiddenApps]
            for appList in appListsToConsider {
                if let app = appList.first(where: { $0.appInfo.relativeBundlePath == selectedBundlePath }) {
                    return app.bundleIdentifier
                }
            }
        }
        return Bundle.main.bundleIdentifier ?? ""
    }

    private func multitaskPIDJITRelayScheme(for appToLaunch: LCAppModel) -> String? {
        let currentScheme = LCUtils.appUrlScheme()?.lowercased()
        let runningScheme = LCSharedUtils.getContainerUsingLCScheme(withFolderName: appToLaunch.uiDefaultDataFolder)
        if let runningScheme,
           runningScheme.lowercased() != currentScheme {
            return runningScheme
        }

        var freeScheme: String?
        LCUtils.forEachInstalledLC(isFree: true) { scheme, shouldBreak in
            if scheme.lowercased() != currentScheme {
                freeScheme = scheme
                shouldBreak = true
            }
        }
        return freeScheme
    }
    
    private func openJITInAnotherLC(encodedURL: String, appToLaunch: LCAppModel, errorMessage: String) async -> Bool {
        let freeScheme = multitaskPIDJITRelayScheme(for: appToLaunch)
        guard let freeScheme else {
            errorInfo = errorMessage
            errorShow = true
            return false
        }

        guard let launchURL = URL(string: "\(freeScheme)://open-url?url=\(encodedURL)") else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return false
        }

        LCUtils.appGroupUserDefault.set(multitaskPIDJITBundleId(for: appToLaunch), forKey: "LCLaunchExtensionBundleID")
        LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
        await UIApplication.shared.open(launchURL)
        return true
    }

    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            
            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    if jitEnabler == .StosDebugLC {
                        if let app = sharedModel.apps.first(where: { app in
                            app.appInfo.urlSchemes().contains("stosdebug") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            let urlString = "stosdebug://enableJIT?bundleId=\(multitaskPIDJITBundleId(for: app))&appName=\(appName)&pid=\(pid)&relaunchApp=false&forcePID=true\(encoded)"
                            let encodedStr = Data(urlString.utf8).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                            Task { _ = await openJITInAnotherLC(encodedURL: encodedStr, appToLaunch: app, errorMessage: "No free LiveContainer is available. Please either: \n(1)close one, \n(2)install a new one, \n(3)choose another method to enable JIT.") }
                        } else {
                            errorInfo = "StosDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        if let url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }

                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                        let targetBundleId = UserDefaults.standard.string(forKey: "selected") ?? targetGuestBundleIdForPIDJIT()
                        let encodedAppName = appName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appName
                        var urlString = "stosdebug://enableJIT?bundleId=\(targetBundleId)&appName=\(encodedAppName)&pid=\(pid)&relaunchApp=false&forcePID=true"
                        if let encodedData, !encodedData.isEmpty {
                            urlString += "&script=\(encodedData)"
                        }
                        if let url = URL(string: urlString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }
            }

            let encodedStikDirect = encodedData.map { "&script-data=\($0)" } ?? ""
                if jitEnabler == .StikJITLC {
                    if let app = sharedModel.apps.first(where: { app in
                        return app.appInfo.urlSchemes().contains("stikjit") &&
                        (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                    }) {
                        let urlString = "stikjit://enable-jit?bundle-id=\(multitaskPIDJITBundleId(for: app))&pid=\(pid)\(encodedStikDirect)"
                        let encodedStr = Data(urlString.utf8).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                        Task { _ = await openJITInAnotherLC(encodedURL: encodedStr, appToLaunch: app, errorMessage: "No free LiveContainer is available. Please either: \n(1)close one, \n(2)install a new one, \n(3)choose another method to enable JIT.") }
                    } else {
                        errorInfo = "StikDebug is not found. Please install it first and switch it to shared app."
                        errorShow = true
                        return
                        }
                    } else if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encodedStikDirect)") {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func installMdm(data: Data) {
        safariViewURL = URL(string:"data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariViewOpened = true
    }
    
    func openNavigationView(view: AnyView) {
        navigateTo = view
        isNavigationActive = true
    }
    
    func promptForGeneratedIconStyle(hasCustomIcon: Bool) async -> GeneratedIconStyle? {
        generatedIconStyleHasCustom = hasCustomIcon
        if #available(iOS 18.0, *) {
            generatedIconStyleShowVariants = true
            return await generatedIconStyleSelector.open()
        } else {
            // pre-iOS 18 has no light/dark/original variants, so only prompt
            // (light vs custom) when there's a custom icon to choose
            generatedIconStyleShowVariants = false
            return hasCustomIcon ? await generatedIconStyleSelector.open() : .Light
        }
    }
    
    func closeNavigationView() {
        isNavigationActive = false
        // Clear destination after the pop animation completes so the
        // navigation bar title restores cleanly without a flash.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            navigateTo = nil
        }
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    func handleURL(url : URL) {
        if url.isFileURL {
            Task { await installFromUrl(urlStr: url.absoluteString) }
            return
        }
        
        if url.scheme == "sidestore" && UserDefaults.sideStoreExist() {
            UserDefaults.standard.setValue(url.absoluteString, forKey: "launchAppUrlScheme")
            LCUtils.openSideStore(delegate: self)
            return
        }
        
        if url.host == "open-web-page" || url.host == "open-url" {
            if let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItem = urlComponent.queryItems?.first {
                if queryItem.value?.isEmpty ?? true {
                    return
                }
                
                if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    Task { await openWebView(urlString: decodedUrl) }
                }
            }
        } else if url.host == "livecontainer-launch" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var bundleId : String? = nil
                var containerName : String? = nil
                var openURL : String? = nil
                var forceJIT: Bool? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "bundle-name", let bundleId1 = queryItem.value {
                        bundleId = bundleId1
                    } else if queryItem.name == "container-folder-name", let containerName1 = queryItem.value {
                        containerName = containerName1
                    } else if queryItem.name == "open-url", let encodedOpenURL = queryItem.value,
                              let decodedData = Data(base64Encoded: encodedOpenURL) {
                        openURL = String(data: decodedData, encoding: .utf8)
                    } else if queryItem.name == "jit", let forceJIT1 = queryItem.value {
                        if forceJIT1 == "true" {
                            forceJIT = true
                        } else if forceJIT1 == "false" {
                            forceJIT = false
                        }
                    }
                }
                if let bundleId, bundleId != "ui"{
                    Task { await launchAppWithBundleId(bundleId: bundleId, container: containerName, openURL: openURL, forceJIT: forceJIT) }
                }
            }
        } else if url.host == "install" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var installUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        installUrl = installUrl1
                    }
                }
                if let installUrl {
                    Task { await installFromUrl(urlStr: installUrl) }
                }
            }
        }
    }
    
    var gridItemWidth: CGFloat {
        appGridShowLabels ? 90 : 92
    }
    
    var gridSpacing: CGFloat {
        appGridShowLabels ? 20 : 18
    }
    
    @ViewBuilder
    func appList(apps: [LCAppModel], hidden: Bool, gridID: String) -> some View {
        if appListInterfaceStyle == .grid {
            let isHiddenAppGrid = gridID == "hiddenApps"
            let gridCoordinateSpace = isHiddenAppGrid ? "LCHiddenAppGrid" : "LCVisibleAppGrid"
            let appFrames = isHiddenAppGrid ? hiddenGridAppFrames : visibleGridAppFrames
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: gridItemWidth), spacing: gridSpacing)], spacing: appGridShowLabels ? 32 : 22) {
                ForEach(apps, id: \.self) { app in
                    if hidden {
                        LCAppSkeletonIcon(showLabels: appGridShowLabels)
                    } else {
                        LCAppBanner(appModel: app, delegate: self, appDataFolders: $sharedModel.appDataFolderNames, tweakFolders: $sharedModel.tweakFolderNames, interfaceStyle: .grid) { _ in
                            cancelGridDrag(draggingApp: $draggingApp, cleanupID: $dragCleanupID)
                        }
                        .onDrag {
                            draggingApp = app
                            scheduleGridDragCleanup(draggingApp: $draggingApp, cleanupID: $dragCleanupID, delay: 30)
                            return NSItemProvider(object: NSString(string: sharedAppSortManager.getUniqueIdentifier(for: app) ?? app.displayName))
                        } preview: {
                            IconImageView(icon: app.appInfo.iconIsDarkIcon(LCUtils.appGroupUserDefault.bool(forKey: "darkModeIcon")))
                                .frame(width: appGridShowLabels ? 72 : 84, height: appGridShowLabels ? 72 : 84)
                        }
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: LCGridAppFramePreferenceKey.self, value: gridFramePreference(for: app, proxy: proxy, coordinateSpace: gridCoordinateSpace))
                            }
                        }
                    }
                }
                .transition(.scale)
            }
            .coordinateSpace(name: gridCoordinateSpace)
            .frame(maxWidth: .infinity)
            .onPreferenceChange(LCGridAppFramePreferenceKey.self) { value in
                if isHiddenAppGrid {
                    hiddenGridAppFrames = value
                } else {
                    visibleGridAppFrames = value
                }
            }
            .onDrop(of: [.text], delegate: LCGridDropDelegate(apps: apps, appFrames: appFrames, draggingApp: $draggingApp, dragCleanupID: $dragCleanupID, sortManager: sharedAppSortManager))
        } else {
            VStack(spacing: 8) {
                ForEach(apps, id: \.self) { app in
                    if hidden {
                        LCAppSkeletonBanner()
                    } else {
                        appRow(app: app, isHidden: gridID == "hiddenApps")
                    }
                }
                .transition(.scale)
            }
        }
    }
    
    func gridFramePreference(for app: LCAppModel, proxy: GeometryProxy, coordinateSpace: String) -> [String: CGRect] {
        guard let uniqueIdentifier = sharedAppSortManager.getUniqueIdentifier(for: app) else {
            return [:]
        }
        return [uniqueIdentifier: proxy.frame(in: .named(coordinateSpace))]
    }
    
    @ViewBuilder
    func appRow(app: LCAppModel, isHidden: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
            LCAppBanner(appModel: app, delegate: self, appDataFolders: $sharedModel.appDataFolderNames, tweakFolders: $sharedModel.tweakFolderNames, updateAction: updateAction(for: app))
                .padding(.leading, isMultiSelectMode ? 36 : 0)
                .animation(.easeInOut(duration: 0.2), value: isMultiSelectMode)
                .allowsHitTesting(!isMultiSelectMode && !isDeleting)

            if isMultiSelectMode {
                let isSelected = selectedAppsForDeletion.contains(app)
                // Selection is action-agnostic now — the same checkbox is used
                // whether you'll end up tapping Delete or Lock/Hide afterward.
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .green : .secondary)
                    .font(.title2)
                    .padding(.leading, 6)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
            .frame(height: 88)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isMultiSelectMode, !isDeleting else { return }
                // Selection is free and action-agnostic: tap any app to
                // select/deselect it, then choose Delete or Lock/Hide afterward.
                withAnimation(.easeInOut(duration: 0.1)) {
                    if selectedAppsForDeletion.contains(app) {
                        selectedAppsForDeletion.remove(app)
                    } else {
                        selectedAppsForDeletion.insert(app)
                    }
                }
            }

            // ── Per-app signing/update progress bar ──
            // Uses a dedicated ObservedObject view so @Published changes trigger re-render.
            AppSigningProgressBar(model: app)
        } // end outer VStack
    }

    /// Installs URLs from sharedModel.pendingInstallURLs one at a time.
    /// Each URL is dequeued before starting so concurrent calls self-cancel.
    /// All items in the pending queue come from the Updates tab so isUpdate=true.
    func drainInstallQueue() async {
        while true {
            guard !sharedModel.pendingInstallURLs.isEmpty else { return }
            let url = sharedModel.pendingInstallURLs.removeFirst()
            // All items from pendingInstallURLs come from Updates tab — always isUpdate=true
            await installFromUrl(urlStr: url.absoluteString, isUpdate: true)
        }
    }

    /// Drains the structured PendingInstall queue one entry at a time.
    /// Each entry carries its own isUpdate flag, appName, and iconURL so
    /// there is no shared-state race. The full flow is: download → wait for
    /// completion → switch to apps tab → install/sign.
    func drainPendingInstallQueue() async {
        // Only one drain loop at a time — subsequent calls exit immediately
        guard !isDrainingInstallQueue else { return }
        isDrainingInstallQueue = true
        defer { isDrainingInstallQueue = false }

        while true {
            guard !sharedModel.pendingInstallQueue.isEmpty else { return }
            let entry = await MainActor.run {
                sharedModel.pendingInstallQueue.removeFirst()
            }
            await MainActor.run {
                if !entry.appName.isEmpty {
                    downloadHelper._pendingLegacyName = entry.appName
                }
                if let icon = entry.iconURL {
                    downloadHelper._pendingIconURL = icon
                }
            }
            await installFromUrl(urlStr: entry.url.absoluteString, isUpdate: entry.isUpdate)
        }
    }

    func deleteSelectedApps() async {
        guard !selectedAppsForDeletion.isEmpty else {
            await MainActor.run {
                errorInfo = "No apps selected. Tap apps in the list to select them first."
                errorShow = true
            }
            return
        }
        
        // Snapshot the set so UI changes mid-loop don't affect iteration
        let appsToDelete = selectedAppsForDeletion
        let removeData = deleteAppData
        // Snapshot container info before deletion (bundle removal would make re-reading unreliable)
        let containerSnapshots: [LCAppModel: [LCContainer]] = Dictionary(uniqueKeysWithValues: appsToDelete.map { ($0, $0.appInfo.containers) })
        let legacyUUIDs: [LCAppModel: String?] = Dictionary(uniqueKeysWithValues: appsToDelete.map { ($0, $0.appInfo.dataUUID) })
        
        await MainActor.run { isDeleting = true }
        
        let fm = FileManager()
        for app in appsToDelete {
            guard let bundlePath = app.appInfo.bundlePath() else { continue }
            do {
                try fm.removeItem(atPath: bundlePath)
                removeApp(app: app)
                if removeData {
                    for container in containerSnapshots[app] ?? [] {
                        // containerURL already accounts for isShared (private vs group path)
                        try? fm.removeItem(at: container.containerURL)

                        // App group isolation folders (both private and shared variants)
                        let privateAppGroup = LCPath.appGroupPath.appendingPathComponent(container.folderName)
                        try? fm.removeItem(at: privateAppGroup)

                        let sharedAppGroup = LCPath.lcGroupAppGroupPath.appendingPathComponent(container.folderName)
                        try? fm.removeItem(at: sharedAppGroup)

                        LCUtils.removeAppKeychain(dataUUID: container.folderName)
                        DispatchQueue.main.async {
                            sharedModel.appDataFolderNames.removeAll { $0 == container.folderName }
                        }
                    }
                    // Legacy: handle apps whose containerInfo was nil but dataUUID exists.
                    // Bootstrap stores these under both private and shared data paths.
                    if let legacyUUID = legacyUUIDs[app] ?? nil {
                        let privateLegacy = LCPath.dataPath.appendingPathComponent(legacyUUID)
                        try? fm.removeItem(at: privateLegacy)

                        let sharedLegacy = LCPath.lcGroupDataPath.appendingPathComponent(legacyUUID)
                        try? fm.removeItem(at: sharedLegacy)

                        DispatchQueue.main.async {
                            sharedModel.appDataFolderNames.removeAll { $0 == legacyUUID }
                        }
                    }
                }
            } catch {
                // continue deleting others even if one fails
            }
        }
        
        await MainActor.run {
            withAnimation {
                selectedAppsForDeletion.removeAll()
                isMultiSelectMode = false
                deleteAppData = false
                isDeleteArmed = false
                isDeleting = false
            }
            sharedModel.isMultiSelectMode = false
        }
    }

    func lockAndHideSelectedApps() async {
        await toggleLockHideSelectedApps()
    }

    /// Handles both directions with per-group action choice dialogs:
    /// - Visible apps → show lock dialog (Lock & Hide / Lock Only / Hide Only / Cancel)
    /// - Hidden apps  → show unhide dialog (Unlock & Unhide / Unhide Only / Cancel)
    /// Both groups are processed simultaneously if both are selected.
    func toggleLockHideSelectedApps() async {
        guard !selectedAppsForDeletion.isEmpty else { return }

        let visibleApps = selectedAppsForDeletion.filter { !$0.appInfo.isHidden }
        let hiddenApps  = selectedAppsForDeletion.filter {  $0.appInfo.isHidden }

        // Ask for lock action if any visible apps are selected
        var lockAction: String? = nil
        if !visibleApps.isEmpty {
            lockAction = await lockHideActionAlert.open()
            guard lockAction != nil else { return } // cancelled
        }

        // Ask for unhide action if any hidden apps are selected
        var unhideAction: String? = nil
        if !hiddenApps.isEmpty {
            unhideAction = await unhideActionAlert.open()
            guard unhideAction != nil else { return } // cancelled
        }

        isDeleting = true

        await MainActor.run {
            // Process visible apps
            if let action = lockAction {
                for app in visibleApps {
                    if action == "lockAndHide" {
                        // Lock switch ON + Hide switch ON → move to hidden section
                        app.appInfo.isLocked = true
                        app.appInfo.isHidden = true
                        app.appInfo.save()
                        // Sync published UI vars so toggles reflect new state
                        app.uiIsLocked = true
                        app.uiIsHidden = true
                        sharedModel.apps.removeAll { $0 == app }
                        if !sharedModel.hiddenApps.contains(app) {
                            sharedModel.hiddenApps.append(app)
                        }
                        if let schemes = app.appInfo.urlSchemes() as? [String] {
                            UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                                .removeObjects(in: schemes)
                        }
                    } else if action == "lockOnly" {
                        // Lock switch ON, Hide switch OFF — app stays visible
                        app.appInfo.isLocked = true
                        app.appInfo.isHidden = false
                        app.appInfo.save()
                        // Sync published UI vars
                        app.uiIsLocked = true
                        app.uiIsHidden = false
                    }
                }
            }

            // Process hidden apps
            if let action = unhideAction {
                for app in hiddenApps {
                    if action == "unhideOnly" {
                        // Hide switch OFF only — lock switch unchanged
                        app.appInfo.isHidden = false
                        app.appInfo.save()
                        // Sync UI vars — only hide toggle switches off
                        app.uiIsHidden = false
                        // uiIsLocked left as-is
                    } else if action == "unlockAndUnhide" {
                        // Both switches OFF
                        app.appInfo.isHidden = false
                        app.appInfo.isLocked = false
                        app.appInfo.save()
                        // Sync both UI vars
                        app.uiIsHidden = false
                        app.uiIsLocked = false
                    }

                    // Move from hidden list back to visible
                    sharedModel.hiddenApps.removeAll { $0 == app }
                    if !sharedModel.apps.contains(app) {
                        sharedModel.apps.append(app)
                    }
                    // Restore URL schemes
                    if let schemes = app.appInfo.urlSchemes() as? [String] {
                        let existing = UserDefaults.lcShared()
                            .array(forKey: "LCGuestURLSchemes") as? [String] ?? []
                        let toAdd = schemes.filter { !existing.contains($0) }
                        UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                            .addObjects(from: toAdd)
                    }
                }
            }

            withAnimation {
                selectedAppsForDeletion.removeAll()
                isMultiSelectMode = false
                isDeleting = false
            }
            sharedModel.isMultiSelectMode = false
        }
    }

    /// Sets the "Ignore Updates" setting for every selected app — they'll stop
    /// appearing in the Updates tab entirely, for any version, until this is
    /// turned back off (per-app, from LCAppSettingsView, or via the inverse
    /// bulk action below).
    func ignoreUpdatesForSelectedApps() {
        guard !selectedAppsForDeletion.isEmpty else { return }
        for app in selectedAppsForDeletion {
            app.appInfo.ignoreUpdates = true
            app.uiIgnoreUpdates = true
        }
        exitMultiSelectAfterMenuAction()
    }

    /// Inverse of the above — clears "Ignore Updates" for every selected app
    /// so they can appear in the Updates tab again.
    func unignoreUpdatesForSelectedApps() {
        guard !selectedAppsForDeletion.isEmpty else { return }
        for app in selectedAppsForDeletion {
            app.appInfo.ignoreUpdates = false
            app.uiIgnoreUpdates = false
        }
        exitMultiSelectAfterMenuAction()
    }

    /// Exiting multiselect flips this toolbar slot's content from a Menu to
    /// a different view (spinner/SideStore/Help). Both ignore/unignore
    /// actions above are triggered from inside that same Menu's own popover
    /// — flipping the toolbar's branch synchronously, on the same run loop
    /// turn as the tap, races the popover's own dismissal animation on iPad
    /// and is what was making the button vanish after being pressed. Giving
    /// the popover a moment to fully close first avoids that race.
    private func exitMultiSelectAfterMenuAction() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation {
                self.selectedAppsForDeletion.removeAll()
                self.isMultiSelectMode = false
            }
            self.sharedModel.isMultiSelectMode = false
        }
    }
    
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}
