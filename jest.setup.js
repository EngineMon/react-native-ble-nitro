// Tests run in Node, without the Nitro runtime: each test mocks the native
// manager factory (src/specs/NativeBleNitroFactory) itself. A test that
// reaches Nitro anyway fails here with a clear message instead of inside
// Nitro's native module loader.
jest.mock('react-native-nitro-modules', () => ({
  NitroModules: {
    createHybridObject: (name) => {
      throw new Error(`A test created the HybridObject ${name}: mock src/specs/NativeBleNitroFactory instead`);
    },
  },
}));
