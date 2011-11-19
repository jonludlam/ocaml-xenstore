(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Lwt
open Xs_packet
module Client = Xs_client.Client(Xs_transport_unix)
open Client

let test () =
  lwt client = make () in
  with_xst client
    (fun xs ->
      lwt all = directory xs "/" in
      List.iter print_endline all;
      lwt x = read xs "/squeezed/pid" in
      print_endline x;
      return ()
    )
  >>
  wait client
    (fun xs ->
      try_lwt
         lwt _ = read xs "/foobar" in
         lwt _ = read xs "/waz" in
         return ()
      with (Enoent _) -> fail Eagain
    )

let ( |> ) a b = b a

type expr =
  | Val of string
  | And of expr * expr
  | Or of expr * expr
  | Eq of expr * expr
  | Not of expr

exception Invalid_expression

(* "type-check" the expr. It should be "(k=v) and (kn=vn)*" *)
let rec to_conjunction = function
  | And(x, y) -> (to_conjunction x) @ (to_conjunction y)
  | Eq(Val k, Val v) -> [ k, v ]
  | _ -> raise Invalid_expression

let parse_expr s =
  let open Genlex in
  let keywords = ["("; ")"; "not"; "="; "and"; "or"] in
  (* Collapse streams of Idents together (eg /a/b/c) *)
  let flatten s =
    let to_list s =
      let result = ref [] in
      Stream.iter (fun x -> result := x :: !result) s;
      List.rev !result in
    let ident is = if is = [] then [] else [Ident (String.concat "" (List.rev is))] in
    let is, tokens = List.fold_left
      (fun (is, tokens) x -> match is, x with
	| is, Ident i -> (i :: is), tokens
	| is, x -> [], (x :: (ident is) @ tokens))
      ([], []) (to_list s) in
    ident is @ tokens
  |> List.rev |> Stream.of_list in
  let rec parse_atom = parser
    | [< 'Int n >] -> Val (string_of_int n)
    | [< 'Ident n >] -> Val n
    | [< 'Float n >] -> Val (string_of_float n)
    | [< 'String n >] -> Val n
    | [< 'Kwd "not"; e=parse_expr >] -> Not(e)
    | [< 'Kwd "("; e=parse_expr; 'Kwd ")" >] -> e
  and parse_expr = parser
    | [< e1=parse_atom; stream >] ->
      (parser
        | [< 'Kwd "and"; e2=parse_expr >] -> And(e1, e2)
        | [< 'Kwd "or"; e2=parse_expr >] -> Or(e1, e2)
        | [< 'Kwd "="; e2=parse_expr >] -> Eq(e1, e2)
            | [< >] -> e1) stream in
  s |> Stream.of_string |> make_lexer keywords |> flatten |> parse_expr

let rec eval_expression expr xs = match expr with
  | Val path ->
    begin try_lwt
      lwt k = read xs path in
      return true
    with Enoent _ ->
      return false
    end
  | Not a ->
    lwt a' = eval_expression a xs in
    return (not(a'))
  | And (a, b) ->
    lwt a' = eval_expression a xs and b' = eval_expression b xs in
    return (a' && b')
  | Or (a, b) ->
    lwt a' = eval_expression a xs and b' = eval_expression b xs in
    return (a' || b')
  | Eq (Val path, Val v) ->
    begin try_lwt
      lwt v' = read xs path in
      return (v = v')
    with Enoent _ ->
      return false
    end
  | _ -> fail Invalid_expression

let main () =
  lwt client = make () in
  match Sys.argv |> Array.to_list |> List.tl with
    | [ "read"; key ] ->
      with_xs client
	(fun xs ->
	  lwt v = read xs key in
	  Lwt_io.write Lwt_io.stdout v
        ) >> return ()
    | "write" :: expr ->
      begin lwt items = try_lwt
        String.concat " " expr |> parse_expr |> to_conjunction |> return
      with Invalid_expression as e ->
	Lwt_io.write Lwt_io.stderr "Invalid expression; expected <key=val> [and key=val]*\n" >> raise_lwt e in
      with_xs client
	(fun xs ->
	  Lwt_list.iter_s (fun (k, v) -> write xs k v) items
	) >> return ()
      end
    | "wait" :: expr ->
      begin try_lwt
        let expr = String.concat " " expr |> parse_expr in
        wait client
	  (fun xs ->
	    lwt result = eval_expression expr xs in
            if not result then fail Eagain else return ()
          )
      with Invalid_expression as e ->
	Lwt_io.write Lwt_io.stderr "Invalid expression\n" >> raise_lwt e
      end
    | _ ->
      return ()

  (* read key *)
  (* write key=value *)
  (* write key1=value1 key2=value2 *)
  (* wait not key or (key1 = value2) or key3 *)
let _ =
  Lwt_main.run (main ())
