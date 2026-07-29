import FileConvertCore
import FileConvertProviders
import Testing

@Test
func modulesLoadTogether() async {
    let registry = ProviderRegistry()
    #expect(await registry.capabilities().isEmpty)
}
