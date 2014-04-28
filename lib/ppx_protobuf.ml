open Ast_mapper
open Ast_helper
open Asttypes
open Parsetree
open Longident
open Location

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
| Pbt_nested of pb_field list
and pb_field = {
  pbf_name  : string;
  pbf_key   : int;
  pbf_enc   : pb_encoding;
  pbf_kind  : pb_type;
}

type pb_error =
| Pberr_wrong_ty of core_type
| Pberr_attr_syntax of Location.t
| Pberr_no_key of Location.t
| Pberr_key_invalid of Location.t * int
| Pberr_no_conversion of Location.t * pb_type * pb_encoding

exception Error of pb_error

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
  | Pbt_bool     -> "bool"
  | Pbt_int      -> "int"
  | Pbt_int32    -> "Int32.t"
  | Pbt_int64    -> "Int64.t"
  | Pbt_uint32   -> "Uint32.t"
  | Pbt_uint64   -> "Uint64.t"
  | Pbt_float    -> "float"
  | Pbt_string   -> "string"
  | Pbt_nested n -> assert false

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
    | Error (Pberr_wrong_ty ({ ptyp_loc = loc } as ptyp)) ->
      Some (error ~loc (Printf.sprintf "Type %s does not have a Protobuf mapping"
                                       (with_formatter (fun fmt ->
                                          Pprintast.core_type fmt ptyp))))
    | Error (Pberr_attr_syntax loc) ->
      Some (error ~loc "Attribute syntax is invalid")
    | Error (Pberr_no_key loc) ->
      Some (error ~loc "Field must include a key number, e.g. [@key 42]")
    | Error (Pberr_no_conversion (loc, kind, enc)) ->
      Some (error ~loc (Printf.sprintf "`%s' is not a valid representation for %s"
                                       (string_of_pb_encoding enc)
                                       (string_of_pb_type kind)))
    | Error (Pberr_key_invalid (loc, key)) ->
      if key >= 19000 && key <= 19999 then
        Some (error ~loc (Printf.sprintf "Key %d is in reserved range [19000:19999]" key))
      else
        Some (error ~loc (Printf.sprintf "Key %d is outside of valid range [1:0x1fffffff]" key))
    | _ -> None)

let loc v = mkloc v !default_loc
let lid s = loc (parse s)

let pb_key_of_attrs attrs =
  match List.find (fun ({ txt }, _) -> txt = "key") attrs with
  | { loc }, PStr [{ pstr_desc = Pstr_eval ({
                        pexp_desc = Pexp_constant (Const_int key) }, _) }] ->
    if key < 1 || key > 0x1fffffff || (key >= 19000 && key <= 19999) then
      raise (Error (Pberr_key_invalid (loc, key)));
    key
  | { loc }, _ -> raise (Error (Pberr_attr_syntax loc))

let pb_encoding_of_attrs attrs =
  match List.find (fun ({ txt }, _) -> txt = "encoding") attrs with
  | _, PStr [{ pstr_desc = Pstr_eval ({
                pexp_desc = Pexp_ident { txt = Lident kind; loc } }, _) }] ->
    begin try
      pb_encoding_of_string kind
    with Not_found ->
      raise (Error (Pberr_attr_syntax loc))
    end
  | { loc }, _ -> raise (Error (Pberr_attr_syntax loc))

let fields_of_ptype ptype =
  let rec field_of_ptyp pbf_key pbf_name ptyp =
    match ptyp with
    | { ptyp_desc = Ptyp_constr (lid, args); ptyp_attributes = attrs; ptyp_loc; } ->
      let pbf_kind =
        match args, lid with
        | [], { txt = Lident "bool"   } -> Pbt_bool
        | [], { txt = Lident "int"    } -> Pbt_int
        | [], { txt = Lident "float"  } -> Pbt_float
        | [], { txt = Lident "string" } -> Pbt_string
        | [], { txt = Lident "int32" }
        | [], { txt = Ldot (Lident "Int32", "t") }  -> Pbt_int32
        | [], { txt = Lident "int64" }
        | [], { txt = Ldot (Lident "Int64", "t") }  -> Pbt_int64
        | [], { txt = Lident "uint32" }
        | [], { txt = Ldot (Lident "Uint32", "t") } -> Pbt_uint32
        | [], { txt = Lident "uint64" }
        | [], { txt = Ldot (Lident "Uint64", "t") } -> Pbt_uint64
        | _,  { txt = ty } -> raise (Error (Pberr_wrong_ty ptyp))
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
          match pbf_kind with
          | Pbt_bool  -> Pbe_bool
          | Pbt_int   -> Pbe_varint
          | Pbt_float -> Pbe_bits64
          | Pbt_int32  | Pbt_uint32   -> Pbe_bits32
          | Pbt_int64  | Pbt_uint64   -> Pbe_bits64
          | Pbt_string | Pbt_nested _ -> Pbe_bytes
      in
      begin match pbf_kind, pbf_enc with
      | Pbt_bool, Pbe_bool
      | (Pbt_int | Pbt_int32 | Pbt_int64 | Pbt_uint32 | Pbt_uint64),
        (Pbe_varint | Pbe_zigzag | Pbe_bits32 | Pbe_bits64)
      | Pbt_float, (Pbe_bits32 | Pbe_bits64)
      | Pbt_string, Pbe_bytes ->
        { pbf_name; pbf_key; pbf_enc; pbf_kind; }
      | _ ->
        raise (Error (Pberr_no_conversion (ptyp_loc, pbf_kind, pbf_enc)))
      end
    | { ptyp_desc = Ptyp_alias (ptyp', _) } ->
      field_of_ptyp pbf_key pbf_name ptyp'
    | ptyp -> raise (Error (Pberr_wrong_ty ptyp))
  in
  match ptype with
  | { ptype_kind = Ptype_abstract; ptype_manifest = Some ptyp } ->
    [field_of_ptyp (Some 1) "field" ptyp]
  | _ -> assert false

let derive_reader ({ ptype_name } as ptype) =
  let rec mk_cells fields k =
    match fields with
    | field :: rest ->
      Exp.let_ Nonrecursive
               [Vb.mk (Pat.var (loc field.pbf_name))
                      (Exp.apply (Exp.ident (lid "ref"))
                        ["", (Exp.construct (lid "None") None)])]
               (mk_cells rest k)
    | [] -> k
  in
  let mk_reader pbf_enc pbf_kind reader =
    let value =
      Exp.apply (Exp.ident (lid
          ("Protobuf.Reader." ^ (string_of_pb_encoding pbf_enc))))
        ["", reader]
    in
    match pbf_kind, pbf_enc with
    (* bool *)
    | Pbt_bool, Pbe_bool -> value
    (* int *)
    | Pbt_int, (Pbe_varint | Pbe_zigzag | Pbe_bits64) ->
      Exp.apply (Exp.ident (lid "Protobuf.Reader.int_of_int64")) ["", value]
    | Pbt_int, Pbe_bits32 ->
      Exp.apply (Exp.ident (lid "Protobuf.Reader.int_of_int32")) ["", value]
    (* int32 *)
    | Pbt_int32, Pbe_bits32 -> value
    | Pbt_int32, (Pbe_varint | Pbe_zigzag | Pbe_bits64) ->
      Exp.apply (Exp.ident (lid "Int64.to_int32")) ["", value]
    (* int64 *)
    | Pbt_int64, (Pbe_varint | Pbe_zigzag | Pbe_bits64) -> value
    | Pbt_int64, Pbe_bits32 ->
      Exp.apply (Exp.ident (lid "Int64.of_int32")) ["", value]
    (* uint32 *)
    | Pbt_uint32, Pbe_bits32 ->
      Exp.apply (Exp.ident (lid "Uint32.of_int32")) ["", value]
    | Pbt_uint32, (Pbe_varint | Pbe_zigzag | Pbe_bits64) ->
      Exp.apply (Exp.ident (lid "Uint32.of_int32"))
        ["", Exp.apply (Exp.ident (lid "Int64.to_int32"))
          ["", value]]
    (* uint64 *)
    | Pbt_uint64, (Pbe_varint | Pbe_zigzag | Pbe_bits64) ->
      Exp.apply (Exp.ident (lid "Uint64.of_int64")) ["", value]
    | Pbt_uint64, Pbe_bits32 ->
      Exp.apply (Exp.ident (lid "Uint64.of_int32")) ["", value]
    (* float *)
    | Pbt_float, Pbe_bits32 ->
      Exp.apply (Exp.ident (lid "Int32.float_of_bits")) ["", value]
    | Pbt_float, Pbe_bits64 ->
      Exp.apply (Exp.ident (lid "Int64.float_of_bits")) ["", value]
    (* string *)
    | Pbt_string, Pbe_bytes -> value
    | _ -> assert false
  in
  let rec mk_field_cases fields =
    match fields with
    | { pbf_key; pbf_name; pbf_enc; pbf_kind; } :: rest ->
      (Exp.case (Pat.construct (lid "Some")
                  (Some (Pat.tuple
                    [Pat.constant (Const_int pbf_key);
                      Pat.construct (lid (string_payload_kind_of_pb_encoding pbf_enc)) None])))
                (Exp.sequence
                  (Exp.apply
                    (Exp.ident (lid ":="))
                    ["", Exp.ident (lid pbf_name);
                     "", Exp.construct (lid "Some")
                      (Some (mk_reader pbf_enc pbf_kind (Exp.ident (lid "reader"))))])
                  (Exp.apply (Exp.ident (lid "read"))
                    ["", Exp.construct (lid "()") None]))) ::
      (Exp.case (Pat.construct (lid "Some")
                  (Some (Pat.tuple [Pat.constant (Const_int pbf_key);
                                    Pat.var (loc "kind")])))
                (Exp.apply
                  (Exp.ident (lid "raise"))
                  ["", Exp.construct (lid "Protobuf.Reader.Error")
                    (Some (Exp.construct (lid "Protobuf.Reader.Unexpected_payload")
                      (Some (Exp.tuple
                        [Exp.constant (Const_string (ptype_name.txt, None));
                         Exp.ident (lid "kind")]))))])) ::
      mk_field_cases rest
    | [] -> []
  in
  let fields = fields_of_ptype ptype in
  let matcher =
    Exp.match_ (Exp.apply (Exp.ident (lid "Protobuf.Reader.key"))
                          ["", Exp.ident (lid "reader")])
               ((mk_field_cases fields) @
                [Exp.case (Pat.construct (lid "Some")
                            (Some (Pat.tuple [Pat.any (); Pat.var (loc "kind")])))
                          (Exp.sequence
                            (Exp.apply (Exp.ident (lid "Protobuf.Reader.skip"))
                              ["", Exp.ident (lid "reader");
                               "", Exp.ident (lid "kind")])
                            (Exp.apply (Exp.ident (lid "read"))
                              ["", Exp.construct (lid "()") None]));
                 Exp.case (Pat.construct (lid "None") None)
                          (Exp.construct (lid "()") None)])
  in
  let construct_ptyp pbf_name ptyp =
    match ptyp with
    | { ptyp_desc = Ptyp_constr _; } ->
      Exp.match_ (Exp.apply (Exp.ident (lid "!"))
                            ["", Exp.ident (lid pbf_name)])
                 [Exp.case  (Pat.construct (lid "None") None)
                            (Exp.apply
                              (Exp.ident (lid "raise"))
                              ["", Exp.construct (lid "Protobuf.Reader.Error")
                                (Some (Exp.construct (lid "Protobuf.Reader.Missing_field")
                                  (Some (Exp.constant (Const_string (ptype_name.txt, None))))))]);
                  Exp.case  (Pat.construct (lid "Some") (Some (Pat.var (loc "v"))))
                            (Exp.ident (lid "v"))]
    | _ -> assert false
  in
  let construct_ptype ptype =
    match ptype with
    | { ptype_kind = Ptype_abstract; ptype_manifest = Some ptyp } ->
      construct_ptyp "field" ptyp
    | _ -> assert false
  in
  let reader =
    mk_cells fields (
      Exp.let_  Recursive
                [Vb.mk  (Pat.var (loc "read"))
                        (Exp.fun_ "" None (Pat.construct (lid "()") None)
                                  matcher)]
                        (Exp.sequence
                          (Exp.apply (Exp.ident (lid "read"))
                                     ["", Exp.construct (lid "()") None])
                          (construct_ptype ptype)))
  in
  Vb.mk (Pat.var (loc (ptype_name.txt ^ "_from_protobuf")))
        (Exp.fun_ "" None (Pat.var (loc "reader")) reader)

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
            (List.exists (fun { ptype_attributes = attrs } ->
              List.exists (fun ({ txt }, _) -> txt = "protobuf") attrs) ty_decls) ->
          derive item @ map_types rest
        | item :: rest ->
          mapper.structure_item mapper item :: map_types rest
        | [] -> []
      in
      map_types items
  }

let () = run_main protobuf_mapper
