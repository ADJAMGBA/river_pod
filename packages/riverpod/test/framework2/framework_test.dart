import 'dart:async';

import 'package:mockito/mockito.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod/src/internals.dart';
import 'package:test/test.dart';

import '../utils.dart';

void main() {
  ProviderContainer container;
  final mayHaveChanged = MayHaveChangedMock<int>();
  final didChange = DidChangedMock<int>();

  setUp(() {
    container = ProviderContainer();
  });

  tearDown(() {
    reset(mayHaveChanged);
    reset(didChange);
    container.dispose();
  });

  test('ProviderContainer.children', () {
    final root = ProviderContainer();

    expect(root.debugChildren, isEmpty);

    final mid = ProviderContainer(parent: root);

    expect(root.debugChildren, containsAll(<ProviderContainer>[mid]));
    expect(mid.debugChildren, isEmpty);

    final mid2 = ProviderContainer(parent: root);

    expect(root.debugChildren, containsAll(<ProviderContainer>[mid, mid2]));
    expect(mid.debugChildren, isEmpty);
    expect(mid2.debugChildren, isEmpty);

    final leaf = ProviderContainer(parent: mid);

    expect(root.debugChildren, containsAll(<ProviderContainer>[mid, mid2]));
    expect(mid.debugChildren, containsAll(<ProviderContainer>[leaf]));
    expect(mid2.debugChildren, isEmpty);
    expect(leaf.debugChildren, isEmpty);

    leaf.dispose();

    expect(root.debugChildren, containsAll(<ProviderContainer>[mid, mid2]));
    expect(mid.debugChildren, isEmpty);
    expect(mid2.debugChildren, isEmpty);

    mid.dispose();

    expect(root.debugChildren, containsAll(<ProviderContainer>[mid2]));
    expect(mid2.debugChildren, isEmpty);

    mid2.dispose();

    expect(root.debugChildren, isEmpty);

    root.dispose();
  });

  test('ProviderReference.container exposes the root container', () {
    final root = ProviderContainer();
    final container = ProviderContainer(parent: root);
    final provider = Provider((ref) => ref);

    expect(container.read(provider).container, root);
  });

  group('Provider.name', () {
    test('is directed by the family, if any', () {
      final family = Provider.family<int, int>((ref, _) => 0);

      expect(family(0).name, null);

      final family2 = Provider.family<int, int>((ref, _) => 0, name: 'name');

      expect(family2(0).name, 'name (0)');
      expect(family2(1).name, 'name (1)');
    });
  });

  group('combining providers', () {
    StreamController<int> controller;
    final streamProvider = StreamProvider((ref) => controller.stream);

    setUp(() {
      controller = StreamController<int>(sync: true);
    });
    tearDown(() {
      controller.close();
    });

    test("ref.read doesn't cause recomputing", () {
      var callCount = 0;
      final provider = Provider((ref) {
        callCount++;
        return ref.read(streamProvider).data?.value;
      });

      expect(callCount, 0);
      expect(container.read(provider), null);
      expect(callCount, 1);

      controller.add(42);

      expect(callCount, 1);
      expect(container.read(provider), null);
      expect(callCount, 1);
    });

    test('watch cause recomputing when dependency changes', () {
      var callCount = 0;
      final provider = Provider((ref) {
        callCount++;
        return ref.watch(streamProvider).data?.value;
      });

      expect(callCount, 0);
      expect(container.read(provider), null);
      expect(callCount, 1);

      controller.add(42);

      expect(callCount, 1);
      expect(container.read(provider), 42);
      expect(callCount, 2);
    });

    test("watch is no-op if dependency didn't change", () {
      var callCount = 0;
      final provider = Provider((ref) {
        callCount++;
        return ref.watch(streamProvider).data?.value;
      });

      expect(callCount, 0);
      expect(container.read(provider), null);
      expect(callCount, 1);

      expect(callCount, 1);
      expect(container.read(provider), null);
      expect(callCount, 1);
    });

    test(
        'recomputing a provider calls onDispose and clear the dispose listeners',
        () {
      final onDispose = OnDisposeMock();
      final build = BuildMock();
      final provider = Provider((ref) {
        build();
        ref.onDispose(onDispose);
      });
      final container = ProviderContainer();

      container.read(provider);

      verifyOnly(build, build());
      verifyZeroInteractions(onDispose);

      container.refresh(provider);

      verifyOnly(build, build());
      verifyOnly(onDispose, onDispose());

      container.refresh(provider);

      verifyOnly(build, build());
      verifyOnly(onDispose, onDispose());
    });
  });

  test('disposing child container does not dispose the providers', () {
    final container = ProviderContainer();
    final child = ProviderContainer(parent: container);
    var disposed = false;
    final provider = Provider((ref) {
      ref.onDispose(() => disposed = true);
      return 0;
    });

    expect(child.read(provider), 0);

    child.dispose();

    expect(disposed, false);

    container.dispose();

    expect(disposed, true);
  });

  test('child container uses root overrides', () {
    final provider = Provider((ref) => 0);
    final container = ProviderContainer(
      overrides: [provider.overrideWithValue(42)],
    );
    final child = ProviderContainer(parent: container);

    expect(child.read(provider), 42);
  });

  test(
      'ProviderException not cleared if dependency mayHaveChanged but did not change',
      () {
    var callCount = 0;
    final atom = StateProvider((ref) => 0);
    final dependency = Provider((ref) => ref.watch(atom).state);
    final provider = Provider((ref) {
      callCount++;
      ref.watch(dependency);
      if (callCount == 1) {
        throw Error();
      }
    });

    expect(() => container.read(provider), throwsA(isA<ProviderException>()));
    expect(callCount, 1);

    container.read(atom).state = 0;

    expect(() => container.read(provider), throwsA(isA<ProviderException>()));
    expect(callCount, 1);
  });

  group('ref.listen(provider)', () {
    test('calls listener synchronously on known change', () {
      final a = StateProvider((ref) => 0);
      final b = StateProvider((ref) => 42);
      final onAChange = OnChange<StateController<int>>();
      final onBChange = OnChange<StateController<int>>();

      var buildCount = 0;
      final provider = Provider((ref) {
        buildCount++;
        ref.listen<StateController<int>>(a, onAChange);
        ref.listen<StateController<int>>(b, onBChange);
      });

      final aState = container.read(a);
      final bState = container.read(b);
      container.read(provider);

      expect(buildCount, 1);
      verifyZeroInteractions(onAChange);
      verifyZeroInteractions(onBChange);

      aState.state++;

      verifyOnly(onAChange, onAChange(aState));
      verifyZeroInteractions(onBChange);

      aState.state++;

      verifyOnly(onAChange, onAChange(aState));
      verifyZeroInteractions(onBChange);

      bState.state++;

      verifyOnly(onBChange, onBChange(bState));
      verifyNoMoreInteractions(onBChange);
    });

    test('calls listeners in order', () {
      final dep = StateProvider((ref) => 0);
      final onChange = OnChange<StateController<int>>();
      final onChange2 = OnChange<StateController<int>>();

      final provider = Provider((ref) {
        ref.listen<StateController<int>>(dep, onChange);
        ref.listen<StateController<int>>(dep, onChange2);
      });

      container.read(provider);
      final state = container.read(dep);

      verifyZeroInteractions(onChange);
      verifyZeroInteractions(onChange2);

      state.state++;

      verifyInOrder([
        onChange(state),
        onChange2(state),
      ]);
      verifyNoMoreInteractions(onChange);
      verifyNoMoreInteractions(onChange2);
    });

    test('listeners are cleared on dispose', () async {
      final dep = StateProvider((ref) => 0);
      final onChange = OnChange<StateController<int>>();
      final dispose = OnDisposeMock();

      final provider = Provider.autoDispose((ref) {
        ref.onDispose(dispose);
        ref.listen<StateController<int>>(dep, onChange);
      });

      final depElement = container.readProviderElement(dep);

      expect(depElement.hasListeners, isFalse);

      final sub = container.listen(provider);

      expect(depElement.hasListeners, isTrue);

      sub.close();
      await Future<void>.value();

      verifyOnly(dispose, dispose());
      verifyZeroInteractions(onChange);
      expect(depElement.hasListeners, isFalse);

      container.read(dep).state++;

      verifyZeroInteractions(onChange);
    });

    test('listeners are cleared on refresh', () async {
      final dep = StateProvider((ref) => 0);
      final onChange = OnChange<String>();

      var buildCount = 0;
      final provider = Provider.autoDispose((ref) {
        buildCount++;
        final count = buildCount;
        ref.listen<StateController<int>>(dep, (controller) {
          onChange('$count ${controller.state}');
        });
      });

      container.listen(provider);
      container.read(dep).state++;

      verifyOnly(onChange, onChange('1 1'));

      container.refresh(provider);

      verifyNoMoreInteractions(onChange);

      container.read(dep).state++;

      verifyOnly(onChange, onChange('2 2'));
    });

    test('accepts selectors', () async {
      final dep = StateProvider((ref) => 0);
      final onChange = OnChange<bool>();

      final provider = Provider((ref) {
        ref.listen<bool>(dep.select((v) => v.state.isEven), onChange);
      });

      container.read(provider);
      container.read(dep).state++;

      verifyZeroInteractions(onChange);

      await Future.value(42);

      verifyOnly(onChange, onChange(false));

      container.read(dep).state += 2;

      verifyNoMoreInteractions(onChange);

      container.read(dep).state++;

      verifyOnly(onChange, onChange(true));
    });

    test('does not accepts ScopedProviders', () {}, skip: true);

    test('on .autoDispose providers accepts all RootProviders', () {},
        skip: true);

    test('on non-autoDispose providers accepts only non-autodispose providers',
        () {},
        skip: true);

    test('calls listener at the end of the event-loop on potential change',
        () {},
        skip: true);

    test('no-longer calls listener after one dependency changed', () {},
        skip: true);

    test(
        'one dependency may have changed then another dependency did change does not flush the first dependency',
        () {},
        skip: true);
  });

  group('ref.onChange()', () {
    test('listeners are cleared on dispose', () {}, skip: true);

    test('called synchronously before listeners on change', () {}, skip: true);
  }, skip: true);

  test(
      'supports adding onDispose listeners between dependency change and next read',
      () {
    final dispose = OnDisposeMock();
    final dispose2 = OnDisposeMock();

    final dep = StateProvider((ref) => 0);
    final provider = Provider((ref) {
      ref.watch(dep);
      ref.onDispose(dispose);
      return ref;
    });

    final ref = container.read(provider);

    verifyZeroInteractions(dispose);

    container.read(dep).state++;

    verifyOnly(dispose, dispose());

    ref.onDispose(dispose2);

    expect(container.read(provider), ref);
    verifyOnly(dispose2, dispose2());
    verifyNoMoreInteractions(dispose);
  });

  test('ref.onDispose of dependencies called before listeners', () {
    final dispose = OnDisposeMock();
    final mayHaveChanged = MayHaveChangedMock<StateController<int>>();
    final didChange = DidChangedMock<StateController<int>>();

    final dep = StateProvider((ref) => 0);
    final provider = Provider((ref) {
      ref.watch(dep);
      ref.onDispose(dispose);
    });

    final sub = container.listen(
      dep,
      mayHaveChanged: mayHaveChanged,
      didChange: didChange,
    );

    container.read(provider);

    verifyZeroInteractions(dispose);
    verifyZeroInteractions(mayHaveChanged);
    verifyZeroInteractions(didChange);

    container.read(dep).state++;

    verifyInOrder([
      mayHaveChanged(sub),
      dispose(),
      didChange(sub),
    ]);

    verifyNoMoreInteractions(dispose);
    verifyNoMoreInteractions(mayHaveChanged);
    verifyNoMoreInteractions(didChange);
  });

  test('ref.onDispose is not called synchronously on peer-dependency change',
      () {
    final dispose = OnDisposeMock();
    final peerDep = StateProvider((ref) => 0);
    final dep = Provider((ref) => ref.watch(peerDep).state);
    final provider = Provider((ref) {
      ref.onDispose(dispose);
      return ref.watch(dep);
    });

    final sub = container.listen(provider);

    expect(sub.read(), 0);

    verifyZeroInteractions(dispose);

    container.read(peerDep).state++;

    verifyNoMoreInteractions(dispose);

    expect(sub.read(), 1);

    verifyOnly(dispose, dispose());
  });

  test('ref.onDispose called synchronously on dependency change', () {
    final dispose = OnDisposeMock();
    final dep = StateProvider((ref) => 0);
    final provider = Provider((ref) {
      ref.onDispose(dispose);
      return ref.watch(dep).state;
    });

    final sub = container.listen(provider);

    expect(sub.read(), 0);

    verifyZeroInteractions(dispose);

    container.read(dep).state++;

    verifyOnly(dispose, dispose());

    container.read(dep).state++;

    verifyNoMoreInteractions(dispose);

    expect(sub.read(), 2);

    verifyNoMoreInteractions(dispose);
  });

  test('re-evaluating a provider can stop listening to a dependency', () {
    final first = StateProvider((ref) => 0, name: 'first');
    final second = StateProvider((ref) => 0, name: 'second');
    final computed = Provider<String>((ref) {
      if (ref.watch(first).state == 0) {
        return ref.watch(second).state.toString();
      }
      return 'fallback';
    }, name: 'computed');
    final firstElement = container.readProviderElement(first);
    final secondElement = container.readProviderElement(second);
    final computedElement = container.readProviderElement(computed);
    final sub = container.listen(computed);

    expect(sub.read(), '0');
    expect(firstElement.dependents, {computedElement});
    expect(firstElement.hasListeners, true);
    expect(secondElement.dependents, {computedElement});
    expect(secondElement.hasListeners, true);

    container.read(first).state++;
    expect(sub.read(), 'fallback');

    expect(firstElement.dependents, {computedElement});
    expect(firstElement.hasListeners, true);
    expect(secondElement.dependents, <ProviderElement>{});
    expect(secondElement.hasListeners, false);
  });

  group('overrideWithValue', () {
    test('synchronously overrides the value', () {
      var callCount = 0;
      final provider = FutureProvider((ref) async {
        callCount++;
        return 0;
      });
      final container = ProviderContainer(overrides: [
        provider.overrideWithValue(const AsyncValue.data(42)),
      ]);

      addTearDown(container.dispose);

      final sub = container.listen(provider);

      expect(callCount, 0);
      expect(sub.read(), const AsyncValue.data(42));
    });

    test('notify listeners when override value changes', () {
      final provider = Provider((ref) => 0);
      final container = ProviderContainer(overrides: [
        provider.overrideWithValue(42),
      ]);

      addTearDown(container.dispose);

      final sub = container.listen(
        provider,
        mayHaveChanged: mayHaveChanged,
        didChange: didChange,
      );

      verifyZeroInteractions(mayHaveChanged);
      verifyZeroInteractions(didChange);

      container.updateOverrides([
        provider.overrideWithValue(21),
      ]);

      verifyOnly(mayHaveChanged, mayHaveChanged(sub));
      verifyOnly(didChange, didChange(sub));

      expect(sub.read(), 21);

      verifyNoMoreInteractions(mayHaveChanged);
    });

    test('does not notify listeners if updated with the same value', () {
      final provider = Provider((ref) => 0);
      final container = ProviderContainer(overrides: [
        provider.overrideWithValue(42),
      ]);

      addTearDown(container.dispose);

      final sub = container.listen(
        provider,
        mayHaveChanged: mayHaveChanged,
        didChange: didChange,
      );

      verifyZeroInteractions(mayHaveChanged);
      verifyZeroInteractions(didChange);

      container.updateOverrides([
        provider.overrideWithValue(42),
      ]);

      verifyZeroInteractions(didChange);
      verifyZeroInteractions(mayHaveChanged);

      expect(sub.read(), 42);
    });
  });

  test('remove dependencies on dispose', () async {
    final first = StateProvider((ref) => 0);
    final computed = Provider.autoDispose((ref) {
      return ref.watch(first).state;
    });
    final firstElement = container.readProviderElement(first);
    final computedElement = container.readProviderElement(computed);
    final sub = container.listen(computed);

    expect(sub.read(), 0);
    expect(firstElement.dependents, {computedElement});
    expect(firstElement.hasListeners, true);

    sub.close();
    await Future<void>.value();

    expect(firstElement.dependents, <ProviderElement>{});
    expect(firstElement.hasListeners, false);
  });

  test(
      'ProviderContainer.read(MyProvider.autoDispose) disposes the provider if not listened',
      () async {
    final provider = StateProvider.autoDispose((ref) => 0);

    final state = container.read(provider);

    expect(state.mounted, true);

    await Future<void>.value();

    expect(state.mounted, false);
  });

  group('Element.listen', () {
    group('didChange', () {
      group('on known change', () {
        test('is called synchronously on change', () {
          final counter = Counter();
          final provider = StateNotifierProvider((ref) => counter);

          final sub = container.listen(
            provider.state,
            didChange: didChange,
          );

          verifyZeroInteractions(didChange);

          counter.increment();

          verifyOnly(didChange, didChange(sub));

          counter.increment();

          verifyOnly(didChange, didChange(sub));

          expect(sub.read(), 2);

          verifyNoMoreInteractions(didChange);
        });
      });

      group('on dependency change', () {
        test('is called next sub.read', () {
          final counter = Counter();
          final dependency = StateNotifierProvider((ref) => counter);
          final provider = Provider((ref) => ref.watch(dependency.state));

          final sub = container.listen(
            provider,
            didChange: didChange,
          );

          verifyZeroInteractions(didChange);

          counter.increment();

          verifyZeroInteractions(didChange);

          expect(sub.read(), 1);

          verifyOnly(didChange, didChange(sub));
        });

        test('is called at most once per read', () {
          final counter = Counter();
          final dependency = StateNotifierProvider((ref) => counter);
          final provider = Provider((ref) => ref.watch(dependency.state));

          final sub = container.listen(
            provider,
            didChange: didChange,
          );

          verifyZeroInteractions(didChange);

          counter.increment();
          counter.increment();
          counter.increment();

          verifyZeroInteractions(didChange);
          expect(sub.read(), 3);
          verifyOnly(didChange, didChange(sub));
        });

        test('are all executed after one read call', () {
          final counter = Counter();
          final dependency = StateNotifierProvider((ref) => counter);
          final provider = Provider((ref) => ref.watch(dependency.state));
          final didChange2 = DidChangedMock<int>();

          final sub = container.listen(
            provider,
            didChange: didChange,
          );
          final sub2 = container.listen(
            provider,
            didChange: didChange2,
          );

          counter.increment();

          verifyZeroInteractions(didChange);
          verifyZeroInteractions(didChange2);

          expect(sub.read(), 1);

          verifyOnly(didChange, didChange(sub));
          verifyOnly(didChange2, didChange2(sub2));
        });

        test('is guarded', () {
          final counter = Counter();
          final dependency = StateNotifierProvider((ref) => counter);
          final provider = Provider((ref) => ref.watch(dependency.state));
          final didChange2 = DidChangedMock<int>();
          when(didChange(any)).thenThrow(42);
          when(didChange2(any)).thenThrow(21);

          final sub = container.listen(
            provider,
            didChange: didChange,
          );
          final sub2 = container.listen(
            provider,
            didChange: didChange2,
          );

          counter.increment();

          final errors = errorsOf(sub.read);

          verifyOnly(didChange, didChange(sub));
          verifyOnly(didChange2, didChange2(sub2));

          expect(errors, unorderedEquals(<Object>[42, 21]));
        });
      });
    });

    group('mayHaveChanged', () {
      test('is optional', () {
        final counter = Counter();
        final counterProvider = StateNotifierProvider((ref) => counter);
        final provider = Provider((ref) => ref.watch(counterProvider.state));

        container.listen(provider);

        // Does not crash
        counter.increment();
      });

      test(
          'is synchronously after a change'
          ' without re-evaluating the provider', () {
        final counter = Counter();
        final counterProvider = StateNotifierProvider((ref) => counter);
        var callCount = 0;
        final provider = Provider((ref) {
          callCount++;
          return ref.watch(counterProvider.state);
        });

        final sub = container.listen(provider, mayHaveChanged: mayHaveChanged);

        expect(callCount, 1);
        verifyNoMoreInteractions(mayHaveChanged);

        counter.increment();

        expect(callCount, 1);
        verifyOnly(mayHaveChanged, mayHaveChanged(sub));
      });

      test(
          're-evaluating the provider with a new value calls mayHaveChanged only once',
          () {
        final counter = Counter();
        final counterProvider = StateNotifierProvider((ref) => counter);
        final provider = Provider((ref) {
          return ref.watch(counterProvider.state);
        });

        final sub = container.listen(provider, mayHaveChanged: mayHaveChanged);

        counter.increment();
        sub.read();

        verifyOnly(mayHaveChanged, mayHaveChanged(sub));
      });

      test('is called only onces after multiple changes', () {
        final counter = Counter();
        final counterProvider = StateNotifierProvider((ref) => counter);
        final provider = Provider((ref) {
          return ref.watch(counterProvider.state);
        });

        final sub = container.listen(provider, mayHaveChanged: mayHaveChanged);

        counter.increment();
        counter.increment();

        verifyOnly(mayHaveChanged, mayHaveChanged(sub));
      });
    });

    test("doesn't trow when creating a provider that failed", () {
      final provider = Provider((ref) {
        throw Error();
      });

      final sub = container.listen(provider);

      expect(sub, isA<ProviderSubscription>());
    });

    test('is guarded', () {
      final counter = Counter();
      final provider = StateNotifierProvider((ref) => counter);
      final mayHaveChanged2 = MayHaveChangedMock<int>();
      when(mayHaveChanged(any)).thenThrow(42);
      when(mayHaveChanged2(any)).thenThrow(21);

      final sub = container.listen(
        provider.state,
        mayHaveChanged: mayHaveChanged,
      );
      final sub2 = container.listen(
        provider.state,
        mayHaveChanged: mayHaveChanged2,
      );

      final errors = errorsOf(counter.increment);

      verifyOnly(mayHaveChanged, mayHaveChanged(sub));
      verifyOnly(mayHaveChanged2, mayHaveChanged2(sub2));

      expect(errors, unorderedEquals(<Object>[42, 21]));
    });
  });

  group('ProviderSubscription', () {
    test('no-longer call listeners anymore after close', () {
      final counter = Counter();
      final first = StateNotifierProvider((ref) => counter);
      final provider = Provider((ref) => ref.watch(first.state));
      final element = container.readProviderElement(provider);

      expect(element.hasListeners, false);

      final sub = container.listen(
        provider,
        mayHaveChanged: mayHaveChanged,
        didChange: didChange,
      );

      expect(element.hasListeners, true);

      sub.close();
      counter.increment();

      expect(element.hasListeners, false);
      verifyZeroInteractions(mayHaveChanged);
      verifyZeroInteractions(didChange);
    });

    group('.read', () {
      test('rethrows the exception thrown when building a provider', () {
        final error = Error();
        final provider = Provider<int>((ref) => throw error, name: 'hello');

        final sub = container.listen(provider);

        expect(
          sub.read,
          throwsA(
            isA<ProviderException>()
                .having((s) => s.exception, 'exception', error)
                .having((s) => s.provider, 'provider', provider)
                .having((s) => s.stackTrace, 'stackTrace', isA<StackTrace>())
                .having(
                  (s) => s.toString().split('\n').first,
                  'toString',
                  equalsIgnoringHashCodes(
                    'An exception was thrown while building Provider<int>#00000(name: hello).',
                  ),
                ),
          ),
        );
      });

      test('flushes the provider', () {
        final counter = Counter();
        final first = StateNotifierProvider((ref) => counter);
        final provider = Provider((ref) => ref.watch(first.state));

        final sub = container.listen(provider);

        expect(sub.read(), 0);

        counter.increment();

        expect(sub.read(), 1);
      });
    });

    group('.flush', () {
      test('initialized to true', () {
        final provider = Provider((ref) => 0);
        final sub = container.listen(provider);

        expect(sub.flush(), true);
      });

      test('updates to false after a read', () {
        final provider = Provider((ref) => 0);
        final sub = container.listen(provider);

        sub.read();

        expect(sub.flush(), false);
      });

      test('updates to true after a change', () {
        final counter = Counter();
        final provider = StateNotifierProvider((ref) => counter);

        final sub = container.listen(provider.state);

        sub.read();

        counter.increment();

        expect(sub.flush(), true);
      });

      test('flushes providers', () {
        final counter = Counter();
        final first = StateNotifierProvider((ref) => counter);
        var callCount = 0;
        final provider = Provider((ref) {
          callCount++;
          return ref.watch(first.state);
        });

        expect(callCount, 0);
        final sub = container.listen(provider);
        expect(sub.read(), 0);
        expect(callCount, 1);
        expect(sub.flush(), false);

        counter.increment();

        expect(callCount, 1);
        expect(sub.flush(), true);
        expect(callCount, 2);
      });
    });
  });

  group('container.refresh', () {
    test('still refresh providers on non-root containers', () {
      final root = ProviderContainer();
      final container = ProviderContainer(parent: root);
      var callCount = 0;
      ProviderReference providerReference;
      var result = 0;
      final provider = Provider((ref) {
        callCount++;
        providerReference = ref;
        return result;
      });

      expect(root.read(provider), 0);
      expect(callCount, 1);
      expect(providerReference.container, root);

      result = 1;

      expect(container.refresh(provider), 1);
      expect(container.read(provider), 1);
      expect(callCount, 2);
      expect(providerReference.container, root);
    });

    test('Immediatly creates a new value, even if no changes are pending',
        () async {
      var future = Future.value(42);
      var callCount = 0;
      final provider = FutureProvider((_) {
        callCount++;
        return future;
      });
      final container = ProviderContainer();

      await expectLater(container.read(provider.future), completion(42));
      expect(callCount, 1);

      future = Future.value(21);

      await expectLater(container.refresh(provider), completion(21));
      expect(callCount, 2);
      await expectLater(container.read(provider.future), completion(21));
      expect(callCount, 2);
    });

    test('retrying an unmounted provider just mounts it', () async {
      var callCount = 0;
      final provider = FutureProvider((_) {
        callCount++;
        return Future.value(42);
      });
      final container = ProviderContainer();

      expect(callCount, 0);
      await expectLater(container.refresh(provider), completion(42));
      expect(callCount, 1);
      await expectLater(container.read(provider.future), completion(42));
      expect(callCount, 1);
    });

    test(
        'retrying a provider already marked as needing to update do not create the value twice',
        () async {
      var future = Future.value(42);
      var callCount = 0;
      final dep = StateProvider((_) => 0);
      final provider = FutureProvider((ref) {
        callCount++;
        ref.watch(dep);
        return future;
      });
      final container = ProviderContainer();

      await expectLater(container.refresh(provider), completion(42));
      expect(callCount, 1);

      container.read(dep).state++;
      future = Future.value(21);

      expect(callCount, 1);
      await expectLater(container.refresh(provider), completion(21));
      expect(callCount, 2);
      await expectLater(container.read(provider.future), completion(21));
      expect(callCount, 2);
    });
  });
}

class OnDisposeMock extends Mock {
  void call();
}

class BuildMock extends Mock {
  void call();
}

class OnChange<T> extends Mock {
  void call(T value);
}
