import SwiftUI

// Spell the established property wrapper through an alias. Some command-line SDKs
// also export a newer @State macro without shipping its compiler plugin.
typealias ViewState<Value> = SwiftUI.State<Value>
