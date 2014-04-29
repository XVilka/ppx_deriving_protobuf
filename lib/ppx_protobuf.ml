open Longident
open Location
open Asttypes
open Parsetree
open Ast_mapper
open Ast_helper
open Ast_convenience

type pb_encoding =
| Pbe_bool
| Pbe_varint
| Pbe_zigzag
| Pbe_bits32
| Pbe_bits64
| Pbe_bytes
and pb_type =
| Pbt_bool
| Pbt_int
| Pbt_int32
| Pbt_int64
| Pbt_uint32
| Pbt_uint64
| Pbt_float
| Pbt_string
| Pbt_nested of Longident.t
and pb_kind =
| Pbk_required
| Pbk_optional
| Pbk_repeated
and pb_field = {
  pbf_name  : string;
  pbf_key   : int;
  pbf_enc   : pb_encoding;
  pbf_type  : pb_type;
  pbf_kind  : pb_kind;
}

type pb_error =
| Pberr_abstract of type_declaration
| Pberr_wrong_ty of core_type
| Pberr_attr_syntax of Location.t * [ `Key | `Encoding ]
| Pberr_no_key of Location.t
| Pberr_key_invalid of Location.t * int
| Pberr_no_conversion of Location.t * pb_type * pb_encoding

exception Error of pb_error

let string_of_lident lid =
  String.concat "." (Longident.flatten lid)

let string_of_pb_encoding enc =
  match enc with
  | Pbe_bool   -> "bool"
  | Pbe_varint -> "varint"
  | Pbe_zigzag -> "zigzag"
  | Pbe_bits32 -> "bits32"
  | Pbe_bits64 -> "bits64"
  | Pbe_bytes  -> "bytes"

let pb_encoding_of_string str =
  match str with
  | "bool"   -> Pbe_bool
  | "varint" -> Pbe_varint
  | "zigzag" -> Pbe_zigzag
  | "bits32" -> Pbe_bits32
  | "bits64" -> Pbe_bits64
  | "bytes"  -> Pbe_bytes
  | _ -> raise Not_found

let rec string_of_pb_type kind =
  match kind with
  | Pbt_bool   -> "bool"
  | Pbt_int    -> "int"
  | Pbt_int32  -> "Int32.t"
  | Pbt_int64  -> "Int64.t"
  | Pbt_uint32 -> "Uint32.t"
  | Pbt_uint64 -> "Uint64.t"
  | Pbt_float  -> "float"
  | Pbt_string -> "string"
  | Pbt_nested lid -> string_of_lident lid

let string_payload_kind_of_pb_encoding enc =
  "Protobuf." ^
  match enc with
  | Pbe_bool | Pbe_varint | Pbe_zigzag -> "Varint"
  | Pbe_bits32 -> "Bits32"
  | Pbe_bits64 -> "Bits64"
  | Pbe_bytes  -> "Bytes"

let with_formatter f =
  let buf = Buffer.create 16 in
  let fmt = Format.formatter_of_buffer buf in
  f fmt;
  Format.pp_print_flush fmt ();
  Buffer.contents buf

let () =
  Location.register_error_of_exn (fun exn ->
    match exn with
    | Error (Pberr_abstract { ptype_loc = loc }) ->
      Some (errorf ~loc "Type is abstract")
    | Error (Pberr_wrong_ty ({ ptyp_loc = loc } as ptyp)) ->
      Some (errorf ~loc "Type %s does not have a Protobuf mapping"
                        (with_formatter (fun fmt ->
                          (* Get rid of visual noise *)
                          Pprintast.core_type fmt { ptyp with ptyp_attributes = [] })))
    | Error (Pberr_attr_syntax (loc, attr)) ->
      let name, expectation =
        match attr with
        | `Key      -> "key", "a number, e.g. [@key 1]"
        | `Encoding -> "encoding", "one of: bool, varint, zigzag, bits32, bits64, " ^
                                   "bytes, e.g. [@encoding varint]"
      in
      Some (errorf ~loc "@%s attribute syntax is invalid: expected %s" name expectation)
    | Error (Pberr_no_key loc) ->
      Some (errorf ~loc "Type specification must include a key attribute, e.g. int [@key 42]")
    | Error (Pberr_no_conversion (loc, kind, enc)) ->
      Some (errorf ~loc "\"%s\" is not a valid representation for %s"
                        (string_of_pb_encoding enc) (string_of_pb_type kind))
    | Error (Pberr_key_invalid (loc, key)) ->
      if key >= 19000 && key <= 19999 then
        Some (errorf ~loc "Key %d is in reserved range [19000:19999]" key)
      else
        Some (errorf ~loc "Key %d is outside of valid range [1:0x1fffffff]" key)
    | _ -> None)

let mk_loc ?(loc=  !default_loc) v = mkloc v loc
let mk_lid ?loc s = mk_loc ?loc (parse s)

let mangle_lid ?(suffix="") lid =
  match lid with
  | Lident s    -> Lident (s ^ suffix)
  | Ldot (p, s) -> Ldot (p, s ^ suffix)
  | Lapply _    -> assert false

let pb_key_of_attrs attrs =
  match List.find (fun ({ txt }, _) -> txt = "key") attrs with
  | { loc }, PStr [{ pstr_desc = Pstr_eval ({
                        pexp_desc = Pexp_constant (Const_int key) }, _) }] ->
    if key < 1 || key > 0x1fffffff || (key >= 19000 && key <= 19999) then
      raise (Error (Pberr_key_invalid (loc, key)));
    key
  | { loc }, _ -> raise (Error (Pberr_attr_syntax (loc, `Key)))

let pb_encoding_of_attrs attrs =
  match List.find (fun ({ txt }, _) -> txt = "encoding") attrs with
  | _, PStr [{ pstr_desc = Pstr_eval ({
                pexp_desc = Pexp_ident { txt = Lident kind; loc } }, _) }] ->
    begin try
      pb_encoding_of_string kind
    with Not_found ->
      raise (Error (Pberr_attr_syntax (loc, `Encoding)))
    end
  | { loc }, _ -> raise (Error (Pberr_attr_syntax (loc, `Encoding)))

let fields_of_ptype ptype =
  let rec field_of_ptyp pbf_name pbf_key pbf_kind ptyp =
    match ptyp with
    | [%type: [%t? arg] option ] ->
      begin match pbf_kind with
      | Pbk_required -> field_of_ptyp pbf_name pbf_key Pbk_optional arg
      | _ -> raise (Error (Pberr_wrong_ty ptyp))
      end
    | [%type: [%t? arg] array ] | [%type: [%t? arg] list ] ->
      begin match pbf_kind with
      | Pbk_required -> field_of_ptyp pbf_name pbf_key Pbk_repeated arg
      | _ -> raise (Error (Pberr_wrong_ty ptyp))
      end
    | { ptyp_desc = Ptyp_constr ({ txt = lid }, args); ptyp_attributes = attrs; ptyp_loc; } ->
      let pbf_type =
        match args, lid with
        | [], Lident "bool"   -> Pbt_bool
        | [], Lident "int"    -> Pbt_int
        | [], Lident "float"  -> Pbt_float
        | [], Lident "string" -> Pbt_string
        | [], (Lident "int32"  | Ldot (Lident "Int32", "t"))  -> Pbt_int32
        | [], (Lident "int64"  | Ldot (Lident "Int64", "t"))  -> Pbt_int64
        | [], (Lident "uint32" | Ldot (Lident "Uint32", "t")) -> Pbt_uint32
        | [], (Lident "uint64" | Ldot (Lident "Uint64", "t")) -> Pbt_uint64
        | _,  lident -> Pbt_nested lident
      in
      let pbf_key =
        try  pb_key_of_attrs attrs
        with Not_found ->
          match pbf_key with
          | Some k -> k
          | None -> raise (Error (Pberr_no_key ptyp_loc))
      in
      let pbf_enc =
        try  pb_encoding_of_attrs attrs
        with Not_found ->
          match pbf_type with
          | Pbt_bool   -> Pbe_bool
          | Pbt_int    -> Pbe_varint
          | Pbt_float  -> Pbe_bits64
          | Pbt_string | Pbt_nested _ -> Pbe_bytes
          | Pbt_int32  | Pbt_uint32  -> Pbe_bits32
          | Pbt_int64  | Pbt_uint64  -> Pbe_bits64
      in
      begin match pbf_type, pbf_enc with
      | Pbt_bool, Pbe_bool
      | (Pbt_int | Pbt_int32 | Pbt_int64 | Pbt_uint32 | Pbt_uint64),
        (Pbe_varint | Pbe_zigzag | Pbe_bits32 | Pbe_bits64)
      | Pbt_float, (Pbe_bits32 | Pbe_bits64)
      | (Pbt_string | Pbt_nested _), Pbe_bytes ->
        { pbf_name; pbf_key; pbf_enc; pbf_type; pbf_kind; }
      | _ ->
        raise (Error (Pberr_no_conversion (ptyp_loc, pbf_type, pbf_enc)))
      end
    | { ptyp_desc = Ptyp_alias (ptyp', _) } ->
      field_of_ptyp pbf_name pbf_key pbf_kind ptyp'
    | ptyp -> raise (Error (Pberr_wrong_ty ptyp))
  in
  match ptype with
  | { ptype_kind = Ptype_abstract; ptype_manifest = Some { ptyp_desc = Ptyp_tuple ptyps } } ->
    ptyps |> List.mapi (fun i ptyp ->
      field_of_ptyp (Printf.sprintf "field_%d" i) (Some (i + 1)) Pbk_required ptyp)
  | { ptype_kind = Ptype_abstract; ptype_manifest = Some ptyp } ->
    [field_of_ptyp "field" (Some 1) Pbk_required ptyp]
  | { ptype_kind = Ptype_abstract; ptype_manifest = None } ->
    raise (Error (Pberr_abstract ptype))
  | { ptype_kind = Ptype_record fields } ->
    fields |> List.mapi (fun i { pld_name; pld_type; } ->
      field_of_ptyp ("field_" ^ pld_name.txt) None Pbk_required pld_type)
  | _ -> assert false

let derive_reader ({ ptype_name } as ptype) =
  let rec mk_cells fields k =
    match fields with
    | { pbf_kind = (Pbk_required | Pbk_optional) } as field :: rest ->
      Exp.let_ Nonrecursive
               [Vb.mk (Pat.var (mk_loc field.pbf_name))
                      (Exp.apply (Exp.ident (mk_lid "ref"))
                        ["", (Exp.construct (mk_lid "None") None)])]
               (mk_cells rest k)
    | { pbf_kind = Pbk_repeated } as field :: rest ->
      Exp.let_ Nonrecursive
               [Vb.mk (Pat.var (mk_loc field.pbf_name))
                      (Exp.apply (Exp.ident (mk_lid "ref"))
                        ["", (Exp.construct (mk_lid "[]") None)])]
               (mk_cells rest k)
    | [] -> k
  in
  let mk_reader { pbf_enc; pbf_type; } reader =
    let value =
      let ident = Exp.ident (mk_lid ("Protobuf.Decoder." ^ (string_of_pb_encoding pbf_enc))) in
      [%expr [%e ident] [%e reader]]
    in
    match pbf_type, pbf_enc with
    (* bool *)
    | Pbt_bool, Pbe_bool -> value
    (* int *)
    | Pbt_int, (Pbe_varint | Pbe_zigzag | Pbe_bits64) ->
      [%expr Protobuf.Decoder.int_of_int64 [%e value]]
    | Pbt_int, Pbe_bits32 ->
      [%expr Protobuf.Decoder.int_of_int32 [%e value]]
    (* int32 *)
    | Pbt_int32, Pbe_bits32 -> value
    | Pbt_int32, (Pbe_varint | Pbe_zigzag | Pbe_bits64) ->
      [%expr Int64.to_int32 [%e value]]
    (* int64 *)
    | Pbt_int64, (Pbe_varint | Pbe_zigzag | Pbe_bits64) -> value
    | Pbt_int64, Pbe_bits32 ->
      [%expr Int64.of_int32 [%e value]]
    (* uint32 *)
    | Pbt_uint32, Pbe_bits32 ->
      [%expr Uint32.of_int32 [%e value]]
    | Pbt_uint32, (Pbe_varint | Pbe_zigzag | Pbe_bits64) ->
      [%expr Uint32.of_int32 (Int64.to_int32 [%e value])]
    (* uint64 *)
    | Pbt_uint64, (Pbe_varint | Pbe_zigzag | Pbe_bits64) ->
      [%expr Uint64.of_int64 [%e value]]
    | Pbt_uint64, Pbe_bits32 ->
      [%expr Uint64.of_int32 [%e value]]
    (* float *)
    | Pbt_float, Pbe_bits32 ->
      [%expr Int32.float_of_bits [%e value]]
    | Pbt_float, Pbe_bits64 ->
      [%expr Int64.float_of_bits [%e value]]
    (* string *)
    | Pbt_string, Pbe_bytes -> value
    (* nested *)
    | Pbt_nested lid, Pbe_bytes ->
      let ident = Exp.ident (mk_loc (mangle_lid ~suffix:"_from_protobuf" lid)) in
      [%expr [%e ident] (Protobuf.Decoder.nested [%e reader])]
    | _ -> assert false
  in
  let rec mk_field_cases fields =
    match fields with
    | { pbf_key; pbf_name; pbf_enc; pbf_type; pbf_kind } as field :: rest ->
      let updated =
        match pbf_kind with
        | Pbk_required | Pbk_optional ->
          [%expr Some [%e mk_reader field (evar "reader")]]
        | Pbk_repeated ->
          [%expr [%e mk_reader field (evar "reader")] :: ![%e evar pbf_name]]
      in
      let payload_enc = string_payload_kind_of_pb_encoding pbf_enc in
      (Exp.case [%pat? Some ([%p pint pbf_key], [%p pconstr payload_enc []])]
                [%expr [%e evar pbf_name] := [%e updated]; read ()]) ::
      (Exp.case [%pat? Some ([%p pint pbf_key], kind)]
                [%expr raise Protobuf.Decoder.(Failure
                              (Unexpected_payload ([%e str ptype_name.txt], kind)))]) ::
      mk_field_cases rest
    | [] -> []
  in
  let fields = fields_of_ptype ptype in
  let matcher =
    Exp.match_ [%expr Protobuf.Decoder.key reader]
               ((mk_field_cases fields) @
                [Exp.case [%pat? Some (_, kind)]
                          [%expr Protobuf.Decoder.skip reader kind; read ()];
                 Exp.case [%pat? None] [%expr ()]])
  in
  let construct_ptyp pbf_name ptyp =
    match ptyp with
    | [%type: [%t? _] option] ->
      [%expr ![%e evar pbf_name]]
    | [%type: [%t? _] list] ->
      [%expr List.rev (![%e evar pbf_name])]
    | [%type: [%t? _] array] ->
      [%expr Array.of_list (List.rev (![%e evar pbf_name]))]
    | { ptyp_desc = Ptyp_constr _; } ->
      [%expr
        match ![%e evar pbf_name] with
        | None   -> raise Protobuf.Decoder.(Failure (Missing_field [%e str ptype_name.txt]))
        | Some v -> v
      ]
    | _ -> assert false
  in
  let construct_ptype ptype =
    match ptype with
    | { ptype_kind = Ptype_abstract; ptype_manifest = Some { ptyp_desc = Ptyp_tuple ptyps } } ->
      Exp.tuple (List.mapi (fun i ptyp ->
        construct_ptyp (Printf.sprintf "field_%d" i) ptyp) ptyps)
    | { ptype_kind = Ptype_abstract; ptype_manifest = Some ptyp } ->
      construct_ptyp "field" ptyp
    | { ptype_kind = Ptype_record fields; } ->
      Exp.record (List.mapi (fun i { pld_name; pld_type; } ->
        mk_lid pld_name.txt, construct_ptyp ("field_" ^ pld_name.txt) pld_type) fields) None
    | _ -> assert false
  in
  let reader = mk_cells fields
    [%expr
      let rec read () = [%e matcher] in
      read (); [%e construct_ptype ptype]
    ]
  in
  Vb.mk (Pat.var (mk_loc (ptype_name.txt ^ "_from_protobuf")))
        (Exp.fun_ "" None (Pat.var (mk_loc "reader")) reader)

let derive item =
  match item with
  | { pstr_desc = Pstr_type ty_decls } as item ->
    [item; Str.value Recursive (List.map derive_reader ty_decls)]
  | _ -> assert false

let protobuf_mapper argv =
  { default_mapper with
    structure = fun mapper items ->
      let rec map_types items =
        match items with
        | { pstr_desc = Pstr_type ty_decls } as item :: rest when
            List.exists (fun ty -> has_attr "protobuf" ty.ptype_attributes) ty_decls ->
          derive item @ map_types rest
        | item :: rest ->
          mapper.structure_item mapper item :: map_types rest
        | [] -> []
      in
      map_types items
  }

let () = run_main protobuf_mapper
