(** Copyright 2024-2025, Perevalov Efim, Dyachkov Vitaliy *)

(** SPDX-License-Identifier: LGPL-3.0-or-later *)

open Angstrom
open Ast
open Base

(** Start parse func *)

let start_parsing parser string = parse_string ~consume:All parser string

(* Base *)

let is_char = function
  | 'a' .. 'z' -> true
  | _ -> false
;;

let is_digit = function
  | '0' .. '9' -> true
  | _ -> false
;;

let is_keyword = function
  | "let"
  | "rec"
  | "fun"
  | "if"
  | "then"
  | "else"
  | "true"
  | "false"
  | "match"
  | "with"
  | "val"
  | "in" -> true
  | _ -> false
;;

let is_whitespace = function
  | ' ' | '\n' | '\t' | '\r' -> true
  | _ -> false
;;

let is_underscore = function
  | c -> Char.equal c '_'
;;

(* S1mple parsers *)

let parse_white_space = take_while is_whitespace
let parse_white_space1 = take_while1 is_whitespace
let parse_empty s = parse_white_space *> s <* parse_white_space
let parse_white_space_str str = parse_white_space *> string_ci str <* parse_white_space
let token s = parse_white_space *> s
let stoken s = parse_white_space *> string s
let stoken1 s = parse_white_space1 *> string s
let brackets p = stoken "(" *> p <* stoken ")"
let brackets_or_not p = brackets p <|> p

let chainl1 e op =
  let rec go acc = lift2 (fun f x -> f acc x) op e >>= go <|> return acc in
  e >>= go
;;

(** Const parsers *)

let parse_bool =
  parse_white_space
  *> ((fun _ -> CBool true)
      <$> string "true"
      <|> ((fun _ -> CBool false) <$> string "false"))
;;

let parse_int =
  let ps = token (option "" (stoken "-" <|> stoken "+")) in
  let pd = take_while1 is_digit in
  lift2 (fun sign digit -> CInt (Int.of_string @@ sign ^ digit)) ps pd
;;

(* Var parsers *)
let constr_type = (fun _ -> TInt) <$> string "int" <|> ((fun _ -> TBool) <$> string "bool")
let parse_arrow = parse_empty @@ stoken "->"

let parse_types =
  fix (fun next ->
    lift3 (fun t1 _ t2 -> TArrow (t1, t2)) constr_type parse_arrow next <|> constr_type)
;;

let parse_type = parse_white_space *> char ':' *> parse_white_space *> parse_types

let check_var cond =
  parse_white_space *> take_while1 cond
  >>= fun v ->
  if is_keyword v
  then fail ("You can not use \"" ^ v ^ "\" keywords as vars")
  else if Char.is_digit @@ String.get v 0
  then fail "Identifier first symbol is letter, not digit"
  else return v
;;

let parse_var =
  parse_white_space
  *>
  let is_entry = function
    | c -> is_char c || is_underscore c || is_digit c
  in
  check_var is_entry
;;

(** Pattern parsers *)

let parse_pvar =
  (fun a -> PVar (a, TUnknown))
  <$> parse_var
  <|> brackets_or_not @@ lift2 (fun a b -> PVar (a, b)) parse_var parse_type
;;

let parse_pconst = (fun v -> PConst v) <$> choice [ parse_int; parse_bool ]
let parse_wild = (fun _ -> PWild) <$> stoken "_"

let parse_tuple parser =
  lift2 (fun a b -> PTuple (a :: b)) (token parser) (many1 (stoken "," *> parser))
;;

let rec constr_con = function
  | [] -> PConst CNil
  | hd :: [] -> hd
  | [ f; s ] -> PCon (f, s)
  | hd :: tl -> PCon (hd, constr_con tl)
;;

let parse_con c =
  lift2
    (fun a b -> constr_con @@ (a :: b))
    (c <* stoken "::" <|> (brackets c <* stoken "::"))
    (sep_by (stoken "::") (c <|> brackets c))
;;

let parse_con_2 parser constructor =
  constructor <$> (stoken "[" *> sep_by1 (stoken ";") parser <* stoken "]")
;;

let parse_pattern =
  fix
  @@ fun pack ->
  let value = parse_wild <|> parse_pconst <|> parse_pvar in
  let tuple = brackets @@ parse_tuple (value <|> pack) in
  let con =
    parse_con (tuple <|> parse_con_2 pack constr_con <|> value)
    <|> parse_con_2 (tuple <|> pack) constr_con
  in
  choice [ con; tuple; value ]
;;

(** Expression type *)

(* EConst *)

let parse_econst = (fun v -> EConst v) <$> choice [ parse_int; parse_bool ]

(* EVar *)

let parse_evar =
  (fun a -> EVar (a, TUnknown))
  <$> parse_var
  <|> brackets @@ lift2 (fun a b -> EVar (a, b)) parse_var parse_type
;;

(* EBinaryOp *)

let parse_op char_op op = stoken char_op *> return (fun e1 e2 -> EBinaryOp (op, e1, e2))
let pmulti = parse_op "*" Mul <|> parse_op "/" Div <|> parse_op "%" Mod
let padd = parse_op "+" Add <|> parse_op "-" Sub

let pcomp =
  parse_op ">=" Greq <|> parse_op ">" Gre <|> parse_op "<=" Leq <|> parse_op "<" Less
;;

let peq = parse_op "=" Eq <|> parse_op "<>" Neq
let pconj = parse_op "&&" And
let pdisj = parse_op "||" Or

let parse_ebinop x =
  let multi = chainl1 x pmulti in
  let add = chainl1 multi padd in
  let comp = chainl1 add pcomp in
  let eq = chainl1 comp peq in
  let conj = chainl1 eq pconj in
  chainl1 conj pdisj <* parse_white_space
;;

(* EIfElse *)

let parse_eifelse i expr =
  lift3
    (fun e1 e2 e3 -> EIfElse (e1, e2, e3))
    (stoken "if" *> i)
    (stoken "then" *> expr)
    (stoken "else" *> expr)
;;

(* EFun *)

let constr_efun pl e = List.fold_right ~init:e ~f:(fun p e -> EFun (p, e)) pl
let parse_fun_args = fix @@ fun p -> many1 parse_pattern <|> brackets p

let parse_efun expr =
  brackets_or_not
  @@ lift2 constr_efun (stoken "fun" *> parse_fun_args) (stoken "->" *> expr)
;;

(* EApp *)

let parse_eapp e1 e2 =
  lift2
    (fun f args -> List.fold_left ~init:f ~f:(fun f arg -> EApp (f, arg)) args)
    (parse_evar <|> brackets e1)
    (many1 (parse_evar <|> e2))
;;

(* ELetIn *)

let parse_rec =
  parse_white_space *> stoken "let" *> option "false" (stoken1 "rec ")
  >>| fun x -> if String.( <> ) x "false" then Rec else Notrec
;;

let parse_rename =
  brackets
  @@ (parse_white_space
      *> choice
           [ string "=" *> return "Eq"
           ; string "<>" *> return "Neq"
           ; string "&&" *> return "And"
           ; string "||" *> return "Or"
           ; string "*" *> return "Mul"
           ; string "/" *> return "Div"
           ; string "%" *> return "Mod"
           ; string "+" *> return "Add"
           ; string "-" *> return "Sub"
           ; string ">=" *> return "Greq"
           ; string ">" *> return "Gre"
           ; string "<=" *> return "Leq"
           ; string "<" *> return "Less"
           ])
  <* parse_white_space
;;

let parse_eletin expr =
  let lift5 f p1 p2 p3 p4 p5 = f <$> p1 <*> p2 <*> p3 <*> p4 <*> p5 in
  lift5
    (fun is_rec name args expr1 expr2 ->
      let expr = constr_efun args expr1 in
      ELetIn (is_rec, name, expr, expr2))
    parse_rec
    (parse_rename <|> parse_var)
    (many parse_pattern)
    (stoken "=" *> expr)
    (stoken "in" *> expr)
;;

(* EList *)

let parse_cons_semicolon_expr parser constructor =
  constructor <$> (stoken "[" *> sep_by1 (stoken ";") parser <* stoken "]")
;;

let rec create_cons_sc = function
  | [] -> EConst CNil
  | hd :: [] when equal_expression hd (EConst CNil) -> EConst CNil
  | hd :: tl -> EList (hd, create_cons_sc tl)
;;

(* ETuple *)

let parse_tuple_expr parser =
  brackets
  @@ lift2
       (fun a b -> ETuple (a :: b))
       (parser <* stoken ",")
       (sep_by1 (stoken ",") parser)
;;

(* Expression parsers *)

let parse_expression =
  fix
  @@ fun pack ->
  let econst = brackets_or_not parse_econst in
  let evar = brackets_or_not parse_evar in
  let tuples =
    parse_tuple_expr
      (econst
       <|> evar
       <|> parse_tuple_expr pack
       <|> parse_cons_semicolon_expr pack create_cons_sc)
  in
  let lists =
    parse_cons_semicolon_expr
      (econst <|> evar <|> tuples <|> parse_cons_semicolon_expr pack create_cons_sc)
      create_cons_sc
  in
  let parse_if =
    parse_ebinop pack
    <|> brackets (parse_ebinop pack <|> parse_eletin pack <|> parse_eapp pack pack)
  in
  let expression pack =
    parse_ebinop pack
    <|> parse_eapp pack pack
    <|> brackets_or_not @@ parse_eifelse parse_if pack
    <|> parse_efun pack
    <|> parse_eletin pack
    <|> brackets @@ choice [ tuples; parse_ebinop pack ]
    <|> lists
  in
  let app_left pack =
    evar
    <|> brackets
          (brackets_or_not @@ parse_eifelse parse_if (expression pack)
           <|> parse_efun pack
           <|> parse_eapp pack pack
           <|> parse_eletin pack)
  in
  let app_right pack =
    brackets
      (parse_ebinop pack
       <|> brackets_or_not @@ parse_eifelse parse_if (expression pack)
       <|> parse_eapp pack pack
       <|> parse_efun pack
       <|> parse_eletin pack)
    <|> evar
    <|> econst
  in
  let eapp =
    parse_eapp (app_left pack) (app_right pack) <|> brackets @@ parse_ebinop pack
  in
  let eifelse = parse_eifelse parse_if (expression pack) in
  let efun =
    brackets_or_not
    @@ parse_efun
         (parse_ebinop pack
          <|> parse_eapp (app_left pack) (app_right pack)
          <|> brackets_or_not @@ parse_eifelse parse_if (expression pack)
          <|> parse_efun pack
          <|> parse_eletin pack)
  in
  let ebinop =
    brackets_or_not
    @@ parse_ebinop
         (parse_eletin pack
          <|> parse_eapp (app_left pack) (app_right pack)
          <|> brackets @@ brackets_or_not @@ parse_eifelse parse_if (expression pack)
          <|> brackets @@ parse_ebinop pack
          <|> evar
          <|> econst)
  in
  let eletin = parse_eletin @@ expression pack <|> brackets @@ parse_eletin pack in
  choice [ eletin; efun; ebinop; eifelse; eapp; lists; tuples; evar; econst ]
;;

(** Binding type *)

let parse_let parse =
  lift4
    (fun flag name args body ->
      let body = constr_efun args body in
      Let (flag, name, body))
    parse_rec
    (parse_rename <|> parse_var)
    (parse_white_space *> many (brackets_or_not parse_pattern))
    (stoken "=" *> parse)
;;

let expr_main = (fun expr -> Expression expr) <$> parse_expression
let parse_bindings = parse_let parse_expression <|> expr_main

let parse_statements =
  sep_by (parse_white_space_str ";;" <|> parse_white_space) parse_bindings
;;

let parse program = parse_string parse_statements program