import SwiftUI

struct DetailViewWithLivePlayer: View {
    @ObservedObject var vm: TranscriptionViewModel
    
    var body: some View {
        NavigationStack {
            DetailView(vm: vm)
                .navigationTitle("Result")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    DetailViewWithLivePlayer(vm: TranscriptionViewModel())
}
