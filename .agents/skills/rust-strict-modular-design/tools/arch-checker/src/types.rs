//! Deciding whether a type mentions a meaning-carrying primitive.

use syn::{GenericArgument, PathArguments, Type};

/// Bare types that must not cross a module boundary.
const PRIMITIVES: &[&str] = &[
    "bool", "char", "str", "String", "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16",
    "u32", "u64", "u128", "usize", "f32", "f64",
];

/// Wrappers that add no meaning, so their arguments are inspected too.
const TRANSPARENT: &[&str] = &[
    "Option", "Result", "Vec", "VecDeque", "Box", "Rc", "Arc", "Cow", "HashMap", "BTreeMap",
    "HashSet", "BTreeSet",
];

/// Whether `ty` exposes a primitive, looking through transparent wrappers.
pub fn mentions_primitive(ty: &Type) -> bool {
    match ty {
        Type::Path(path) => path.path.segments.last().is_some_and(|segment| {
            let name = segment.ident.to_string();
            PRIMITIVES.contains(&name.as_str())
                || (TRANSPARENT.contains(&name.as_str()) && arguments_mention(&segment.arguments))
        }),
        Type::Reference(inner) => mentions_primitive(&inner.elem),
        Type::Slice(inner) => mentions_primitive(&inner.elem),
        Type::Array(inner) => mentions_primitive(&inner.elem),
        Type::Ptr(inner) => mentions_primitive(&inner.elem),
        Type::Paren(inner) => mentions_primitive(&inner.elem),
        Type::Group(inner) => mentions_primitive(&inner.elem),
        Type::Tuple(tuple) => tuple.elems.iter().any(mentions_primitive),
        _ => false,
    }
}

fn arguments_mention(arguments: &PathArguments) -> bool {
    let PathArguments::AngleBracketed(generic) = arguments else {
        return false;
    };
    generic.args.iter().any(|argument| match argument {
        GenericArgument::Type(ty) => mentions_primitive(ty),
        _ => false,
    })
}
