ppx_protobuf
============

_ppx_protobuf_ is a ppx syntax extension that generates [Google Protocol Buffers][pb]
serializers and deserializes from an OCaml type definition.

[pb]: https://developers.google.com/protocol-buffers/

Installation
------------

(Not yet)

    $ opam install ppx_protobuf

Usage
-----

In order to enable _ppx_protobuf_, you need to pass the following switch
to `ocamlc` and `ocamlopt`:

    -ppx ppx_protobuf

If you are using bare OCamlBuild, add the following rule to `myocamlbuild.ml`
and attach the `use_ppx_protobuf` tag to the relevant `.ml` files:

``` ocaml
dispatch begin
  function
  | After_rules ->
    (* ... *)
    flag ["ocaml"; "compile"; "use_ppx_protobuf"] (S[A"-ppx"; A"ppx_protobuf"]);
  | _ -> ()
end
```

If you are using [OASIS][], add the following rules to the `Executable` or `Library`
section:

    ByteOpt:    -ppx ppx_protobuf
    NativeOpt:  -ppx ppx_protobuf

[ocamlbuild]: http://brion.inria.fr/gallium/index.php/Ocamlbuild
[oasis]: http://oasis.forge.ocamlcore.org/

Syntax
------

_ppx_protobuf_ is not a replacement for _protoc_ and it does not attempt to generate
code based on _protoc_ definitions. Instead, it generates code based on OCaml type
definitions.

_ppx_protobuf_-generated serializers are derived from the structure of the type
and several attributes: `@key`, `@encoding` and `@bare`. Generation of the serializer
is triggered by a `@@protobuf` attribute attached to the type definition.

_ppx_protobuf_ generates two functions per type:

``` ocaml
type t = ... [@@protobuf]
val t_from_protobuf : Protobuf.Decoder.t -> t
val t_to_protobuf   : Protobuf.Encoder.t -> t -> unit
```

In order to deserialize a value of type `t` from string `message`, use:

``` ocaml
let decoder = Protobuf.Decoder.of_string message in
let result  = t_from_protobuf decoder in
...
```

In order to serialize a value `input` of type `t`, use:

``` ocaml
let encoder = Protobuf.Encoder.create () in
t_to_protobuf encoder input;
let message = Protobuf.Encoder.to_string encoder in
...
```

### Records

A record is the most obvious counterpart for a Protobuf message. In a record, every
field must have an explicitly defined key. For example, consider this _protoc_
definition and its _ppx_protobuf_ equivalent:

``` protoc
message SearchRequest {
  required string query = 1;
  optional int32 page_number = 2;
  optional int32 result_per_page = 3;
}
```

``` ocaml
type search_request = {
  query           : string     [@key 1];
  page_number     : int option [@key 2];
  result_per_page : int option [@key 3];
} [@@protobuf]
```

_ppx_protobuf_ recognizes and maps `option` to optional fields, and
`list` and `array` to repeated fields.

### Integers

Unlike _protoc_, _ppx_protobuf_ allows a much more flexible mapping between
wire representations of integral types and their counterparts in OCaml.
Any combination of the known integral types (`int`, `int32`, `int64`,
`Int32.t`, `Int64.t`, `Uint32.t` and `Uint64.t`) and wire representations
(`varint`, `zigzag`, `bits32` and `bits64`) is valid. The wire representation
is specified using the `@encoding` attribute.

For example, consider this _protoc_ definition and a compatible _ppx_protobuf_ one:

``` protoc
message Integers {
  required int32   bar = 1;
  required fixed64 baz = 2;
}
```

``` ocaml
type integers = {
  bar : Uint64.t [@key 1] [@encoding varint];
  baz : int      [@key 2] [@encoding bits64];
}
```

When parsing or serializing, the values will be appropriately extended or truncated.
If a value does not fit into the narrower type used for serialization or deserialization,
`Decoder.Error Decoder.Overflow` or `Encoder.Error Encoder.Overflow` is raised.

The following table summarizes equivalence between integral types of _protoc_
and encodings of _ppx_protobuf_:

| Encoding | _protoc_ type                |
| -------- | ---------------------------- |
| varint   | int32, int64, uint32, uint64 |
| zigzag   | sint32, sint64               |
| bits32   | fixed32, sfixed32            |
| bits64   | fixed64, sfixed64            |

By default, OCaml types use the following encoding:

| OCaml type       | Encoding | _protoc_ type  |
| ---------------- | -------- | -------------- |
| int              | varint   | int32 or int64 |
| int32 or Int32.t | bits32   | sfixed32       |
| Uint32.t         | bits32   | fixed32        |
| int64 or Int64.t | bits64   | sfixed64       |
| Uint64.t         | bits64   | fixed64        |

Note that no OCaml type maps to zigzag-encoded `sint32` or `sint64` by default.
It is necessary to use `[@encoding zigzag]` explicitly.

### Floats

Similarly to integers, `float` maps to _protoc_'s `double` by default,
but it is possible to specify the encoding explicitly:

``` protoc
message Floats {
  required float  foo = 1;
  required double bar = 2;
}
```

``` ocaml
type floats = {
  foo : float [@key 1] [@encoding bits32];
  bar : float [@key 2];
} [@@protobuf]
```

### Booleans

`bool` maps to _protoc_'s `bool` and is encoded on wire using `varint`:

``` protoc
message Booleans {
  required bool bar = 1;
}
```

``` ocaml
type booleans = {
  bar : bool [@key 1];
} [@@protobuf]
```

### Strings

`string` maps to _protoc_'s `string` or `bytes` and is encoded on wire using `bytes`:

``` protoc
message Strings {
  required string bar = 1;
  required bytes  baz = 2;
}
```

``` ocaml
type strings = {
  bar : string [@key 1];
  baz : string [@key 2];
} [@@protobuf]
```

### Tuples

A tuple is treated in exactly same way as a record, except that keys are derived
automatically starting at 1. The definition of `search_request` above could be
rewritten as:

``` ocaml
type search_request' = string * int option * int option [@@protobuf]
```

Additionally, a tuple can be used in any context where a scalar value is expected;
in this case, it is equivalent to an anonymous inner message:

``` protoc
message Nested {
  message StringFloatPair {
    required string str = 1;
    required float  flo = 2;
  }
  required int32 foo = 1;
  optional StringFloatPair bar = 2;
}
```

``` ocaml
type nested = {
  foo : int                     [@key 1];
  bar : (string * float) option [@key 2];
} [@@protobuf]
```

### Variants

An OCaml variant types is normally mapped to an entire Protobuf message by _ppx_protobuf_,
as opposed to _protoc_, which maps an `enum` to a simple `varint`. This is done because
OCaml constructors can have arguments, but _protoc_'s `enum`s can not.

Note that even if a type doesn't have any constructor with arguments, it is still mapped
to a message, because it would not be possible to extend the type later with a constructor
with arguments otherwise.

Every constructor must have an explicitly specified key; if the constructor has one argument,
it is mapped to an optional field with the key corresponding to the key of the constructor
plus one. If there is more than one argument, they're treated like a tuple.

Consider this example:

``` protoc
message Variant {
  enum T {
    A = 1;
    B = 2;
    C = 3;
  }
  message C {
    required string foo = 1;
    required string bar = 1;
  }
  required T t = 1;
  optional int32 b = 3; // (B = 2) + 1
  optional C c = 4; // (C = 3) + 1
}
```

``` ocaml
type variant =
| A [@key 1]
| B [@key 2] of int
| C [@key 3] of string * string
[@@protobuf]
```

Note that decoder considers messages which contain more than one optional field
invalid and rejects them.

In order to achieve better compatibility with _protoc_, it is possible to embed
a variant where no constructors have arguments without wrapping it in a message:

``` protoc
enum BareVariant {
  A = 1;
  B = 2;
}
message Container {
  required T value = 1;
}
```

``` ocaml
type bare_variant =
| A [@key 1]
| B [@key 2]
and container = {
  value : bare_variant [@key 1] [@bare];
} [@@protobuf]
```

In practice, if a variant has no constructors with arguments, additional two
functions are generated with the following signatures:

``` ocaml
type t = A | B | ... [@@protobuf]
val t_from_protobuf_bare : Protobuf.Decoder.t -> t
val t_to_protobuf_bare   : Protobuf.Encoder.t -> t -> unit
```

These functions do not expect additional framing; they just parse or serialize
a single `varint`.

### Polymorphic variants

Polymorphic variants are currently not supported; see [bug #6387][b6387].

[b6387]: http://caml.inria.fr/mantis/view.php?id=6387

### Type aliases

A type alias (statement of form `type a = b`) is treated by _ppx_protobuf_ as
a definition of a message with one field with key 1:

``` protoc
message Alias {
  required int32 val = 1;
}
```

``` ocaml
type alias = int [@@protobuf]
```

### Nested messages

When _ppx_protobuf_ encounters a non-scalar type, it generates a call to
the serialization or deserialization function corresponding to the full path
to the type.

Consider this definition:

``` ocaml
type foo = bar * Baz.Quux.t [@@protobuf]
```

The generated deserializer code will refer to `bar_from_protobuf` and
`Baz.Quux.t_from_protobuf`; the serializer code will call `bar_to_protobuf`
and `Baz.Quux.t_to_protobuf`.

### Parametric polymorphism

_ppx_protobuf_ is able to handle polymorphic type definitions. In this case,
the serializing or deserializing function will accept one additional argument
for every type variable; correspondingly, the value of this argument will be
passed to serializer or deserializer of any nested parametric type.

Consider this example:

``` ocaml
type 'a mylist =
| Nil  [@key 1]
| Cons [@key 2] of 'a * 'a mylist
[@@protobuf]
```

Here, the following functions will be generated:

``` ocaml
val mylist_from_protobuf : (Protobuf.Decoder.t -> 'a) -> Protobuf.Decoder.t ->
                           'a mylist
val mylist_to_protobuf   : (Protobuf.Decoder.t -> 'a -> unit) -> Protobuf.Decoder.t ->
                           'a mylist -> unit
```

An example usage would be:

``` ocaml
type a = int [@@protobuf]

let get_ints message =
  let decoder = Protobuf.Decoder.of_string message in
  mylist_from_protobuf a_from_protobuf decoder
```

Error handling
--------------

Both serializers and deserializers rigorously verify their input data. The only
possible exception that can be raised during serialization is
`Protobuf.Encoder.Failure`, and during deserialization is `Protobuf.Decoder.Failure`.

### Decoder errors

The decoder attempts to annotate its failures with useful location information,
but only if that wouldn't cost too much in terms of performance and complexity.

In general, as long as you're using the same protocol on both sides, deserialization
or should never raise. The errors would mainly arise when interoperating
with code generated by _protoc_ that doesn't observe OCaml-specific invariants,
or when handling malicious input.

It discerns these types of failure (represented with `Decoder.Failure` exception):

  * `Incomplete`: the message was truncated or using invalid wire format. Frame
    overruns are likely to produce this as well.
  * `Malformed_field`: an invalid wire type was encountered.
  * `Overflow fld`: an integer field in the message contained a value outside
    the range of the corresponding type, e.g. a `varint` field corresponding
    to `int32` contained `0xffffffff`.
  * `Unexpected_payload (fld, kind)`: a key corresponding to field `fld`
    had a wire type incompatible with the specified encoding, e.g.
    a `varint` wire type for a nested message.
  * `Missing_field fld`: a required field `fld` was missing from the message.
  * `Malformed_variant fld`: a variant `fld` contained a key not corresponding
    to any defined constructor.

The decoder errors refer to fields via so-called "paths"; a path corresponds
to the OCaml syntax for referring to a type, field or constructor, but can
contain additional `/<number>` (e.g. `/0`) component for an immediate tuple.

For example, the `string` field will have the path `Foo.r.ra/1`:

``` ocaml
(* foo.ml *)
type r = {
  ra: (int * string) option [@key 1];
} [@@protobuf]
```

### Encoder errors

The encoder discerns these types of failure (represented with `Encoder.Failure`
exception):

  * `Overflow fld`: an integer value was outside the range of its corresponding
    encoding, e.g. a `int64` containing `0xffffffffffff` was serialized to
    `bits32`.

The encoder errors use the same "path" convention as decoder errors.

Extending protocols
-------------------

TODO: describe

Compatibility
-------------

Protocol Buffers specification [suggests][merge] that if a message contains
multiple instances of a `required` or `optional` nested message, those nested
messages should be merged. However, there is no concept of "merging messages"
accessible to _ppx_protobuf_, and this feature can be considered harmful anyway:
it is far too forgiving of invalid input. Thus, _ppx_protobuf_ doesn't implement
this merging.

Everything else should be entirely compatible with _protoc_.

[merge]: https://developers.google.com/protocol-buffers/docs/encoding#optional

License
-------

[MIT](LICENSE.txt)
