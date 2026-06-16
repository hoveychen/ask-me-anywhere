// Host-side A2UI client functions registered into the card catalog. These let
// a *declarative* A2UI tree express logic the basic catalog can't on its own —
// the agent pushes plain JSON, the host evaluates it. Kept tiny and generic so
// any card (not just the gallery demos) can use them.
import 'package:genui/genui.dart'
    show
        BasicCatalogItems,
        Catalog,
        ClientFunctionReturnType,
        ExecutionContext,
        SynchronousClientFunction;
import 'package:json_schema_builder/json_schema_builder.dart';

/// Name of the [AllAnsweredFunction] as referenced in A2UI `checks` conditions.
const String allAnsweredFn = 'allAnswered';

/// The catalog used to render every card: the basic genui widget set plus
/// AMA's client functions. Built once and shared by [CardDetailView] and tests.
final Catalog cardCatalog = BasicCatalogItems.asCatalog().copyWith(
  newFunctions: const [AllAnsweredFunction()],
);

/// Whether [value] counts as "answered": a non-empty list, a non-blank string,
/// a non-empty map, or any other non-null scalar. An empty list / blank string
/// / null means the question is still open. Exposed for unit testing.
bool isAnswered(Object? value) {
  if (value == null) return false;
  if (value is String) return value.trim().isNotEmpty;
  if (value is Iterable) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

/// A2UI client function: returns true only when *every* argument is answered.
/// Wire it into the catalog (see [cardCatalog]) so a Button's `checks` can keep
/// Confirm disabled until all bound questions have a value — the A2UI-native
/// analogue of AskUserQuestion's "Submit stays disabled until answered".
class AllAnsweredFunction extends SynchronousClientFunction {
  const AllAnsweredFunction();

  @override
  String get name => allAnsweredFn;

  @override
  String get description =>
      'Returns true only when every argument is answered (a non-empty list, '
      'a non-blank string, or a non-null value). Use it in a checks condition '
      'to gate a Confirm/Submit button on all questions being answered.';

  @override
  Schema get argumentSchema => S.object(
        description: 'Any number of values to test; all must be answered.',
      );

  @override
  ClientFunctionReturnType get returnType => ClientFunctionReturnType.boolean;

  @override
  Object? executeSync(Map<String, Object?> args, ExecutionContext context) =>
      args.values.every(isAnswered);
}
