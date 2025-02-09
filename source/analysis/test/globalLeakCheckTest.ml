(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Analysis
open Test

let run_check_module ~type_environment source =
  source
  |> Preprocessing.defines ~include_toplevels:false ~include_nested:true
  |> List.map
       ~f:(fun
            {
              Ast.Node.value =
                { Ast.Statement.Define.signature = { Ast.Statement.Define.Signature.name; _ }; _ };
              _;
            }
          -> name)
  |> List.map ~f:(GlobalLeakCheck.check_qualifier ~type_environment)
  |> List.map ~f:Caml.Option.get
  |> List.concat


let assert_global_leak_errors ~context source expected =
  (* TODO (T142189949): fail when file cannot be parsed correctly instead of silently failing *)
  let source_with_imports = "      from typing import *" ^ source in
  let check ~environment ~source =
    run_check_module ~type_environment:(TypeEnvironment.read_only environment) source
  in
  assert_errors ~context ~check source_with_imports expected


let test_global_assignment context =
  let assert_global_leak_errors = assert_global_leak_errors ~context in
  assert_global_leak_errors {|
      def foo():
         x = y
    |} [];
  assert_global_leak_errors {|
      my_global: int = 1
      def foo():
        x = 1
    |} [];
  assert_global_leak_errors
    (* my_global here is not actually a global, this is a valid assignment *)
    {|
      my_global: int = 1
      def foo():
        my_global = 2
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        non_local = 2
        def inner():
          non_local = 3
        inner()
    |}
    [];
  assert_global_leak_errors {|
      def foo():
        raise Exception()
    |} [];
  assert_global_leak_errors {|
      def foo():
        raise Exception() from Exception()
    |} [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        my_global = 2
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        my_global = a = 2
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        a = my_global = 2
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        x, y = 2, 3
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        my_global, y = 2, 3
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        x, my_global = 2, 3
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        (my_global, my_global), my_global = (1, 2), 3
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `int`.";
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `int`.";
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `int`.";
    ];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        def inner():
          global my_global
          my_global = 2
        inner()
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
         if my_local := 0:
           pass
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        my_local = [1, my_global := 2, 3]
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        if my_global := (a := 3):
          print("hi")
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        if a := (my_global := 3):
          print("hi")
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        global my_global
        my_local = 1
        [my_local, b] = 2, 3
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        global my_global
        [my_global, b] = 2, 3
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        global my_global
        (my_global, b) = 2, 3
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo() -> None:
        global my_global
        [my_global[0], b] = 2, 3
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        global my_global
        my_local = []
        (my_local[0], y) = 123, 456
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        global my_global
        (my_global[0], y) = 123, 456
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        (my_global["x"], y) = 1, 2
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        global my_global
        a, *my_global = [1, 2, 3]
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];

  ()


let test_list_global_leaks context =
  let assert_global_leak_errors = assert_global_leak_errors ~context in
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        my_local = []
        my_local.append(123)
    |}
    [];
  assert_global_leak_errors
    {|
      def foo():
        my_local = []
        my_local[:] = [1,2]
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        my_local = []
        my_local.append
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        my_global[:] = [1,2]
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        my_global.append(123)
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        my_global.append
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        my_local = []
        my_local[0] = 123
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        my_global[0] = 123
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def insert_global_list() -> None:
        my_global.insert(0, 1)
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def extend_global_list() -> None:
        local_list = [1]
        my_global.extend(local_list)
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def iadd_global_list() -> None:
        global my_global
        my_local = []
        my_local += [1]
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def iadd_global_list() -> None:
        global my_global
        my_global += [1]
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def non_mutable_global_call() -> None:
        global my_global
        my_global.copy()
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def test() -> None:
        global my_global
        [
          *my_global.setdefault("x", [1])
        ]
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        global my_global
        ls = [1, my_global.setdefault("a", 2), 3]
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        global my_global
        ls = (1, my_global.setdefault("a", 2), 3)
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        global my_global
        ls = [i for i in range(my_global.setdefault("a", 1))]
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        global my_global
        ls = [my_global.setdefault("a", 1) for _ in range(10)]
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        global my_global
        ls = [i for i in range(10) if i == my_global.setdefault("a", 1)]
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        global my_global
        generator = (i for i in range(my_global.setdefault("a", 1)))
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];

  ()


let test_dict_global_leaks context =
  let assert_global_leak_errors = assert_global_leak_errors ~context in
  assert_global_leak_errors
    {|
      def foo():
        my_local: Dict[str, int] = {}
        my_loca[str(1)] = 1
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        my_global[str(1)] = 1
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        my_global["x"] = 1
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def update_global_dict() -> None:
        local_dict = {"a": 1, "b": 2}
        my_global.update(local_dict)
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def setdefault_global_dict() -> None:
        my_global.setdefault("a", 1)
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def union_update_global_dict() -> None:
        global my_global
        local_dict = {"a": 1, "b": 2}
        my_global |= local_dict
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def test() -> None:
        global my_global
        return {
          **my_global.setdefault("x", {"a": 1})
        }
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        global my_global
        local_dict = {"a": my_global.setdefault("a", 1)}
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        global my_global
        local_dict = {my_global.setdefault("a", 1): "a"}
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        global my_global
        local_dict = {my_global.setdefault("a", 1): i for i in range(10)}
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        global my_global
        local_dict = {i: my_global.setdefault("a", 1) for i in range(10)}
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {"a": 1}
      def foo() -> None:
        global my_global
        local_dict = {i: i for i in range(my_global.setdefault("a", 10))}
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];

  ()


let test_set_global_leaks context =
  let assert_global_leak_errors = assert_global_leak_errors ~context in
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def add_global_set() -> None:
        my_global.add(1)
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Set[int]`."];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def update_my_global() -> None:
        my_global.update({15})
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Set[int]`."];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def ior_my_global() -> None:
        global my_global
        my_global |= {1, 2, 3}
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Set[int]`."];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def intersection_update_my_global() -> None:
        my_global.intersection_update({50, 23})
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Set[int]`."];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def iand_my_global() -> None:
        global my_global
        my_global &= {50, 23}
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Set[int]`."];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def difference_update_my_global() -> None:
        my_global.difference_update({39, 180})
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Set[int]`."];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def isub_my_global() -> None:
        global my_global
        my_global -= {39, 180}
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Set[int]`."];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def symmetric_difference_update_my_global() -> None:
        my_global.symmetric_difference_update({1, 2, 3})
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Set[int]`."];
  assert_global_leak_errors
    {|
      my_global: Set[int] = set()
      def ixor_my_global() -> None:
        global my_global
        my_global ^= {1, 2, 3}
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Set[int]`."];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        global my_global
        ls = {1, my_global.setdefault("a", 2), 3}
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        global my_global
        ls = {i for i in range(my_global.setdefault("a", 1))}
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];

  ()


let test_object_global_leaks context =
  let assert_global_leak_errors = assert_global_leak_errors ~context in
  assert_global_leak_errors
    {|
      class MyClass:
        x: int
        def __init__(self, x: int) -> None:
          self.x = x

      my_global: MyClass = MyClass(1)

      def foo():
        my_global.x = 2
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `test.MyClass`."];
  assert_global_leak_errors
    {|
      class MyClass:
        x: int
        def __init__(self, x: int) -> None:
          self.x = x

        def set_x(x: int) -> None:
          self.x = x

      my_global: MyClass = MyClass(1)

      def foo():
        my_global.set_x(2)
    |}
    [ (* TODO (T142189949): leaks should be detected on object attribute mutations *) ];
  assert_global_leak_errors
    {|
      class MyClass:
        y: int
        def __init__(self, y: int) -> None:
          self.y = y

      class MyClass2:
        x: MyClass
        def __init__(self, x: MyClass) -> None:
          self.x = x

      my_global: MyClass2 = MyClass2(MyClass(1))

      def foo():
        my_global.x.y = 3
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `test.MyClass2`."];
  assert_global_leak_errors
    {|
      import collections
      class MyClass:
        my_list: List[int]
        def __init__(self, x: int) -> None:
          self.my_list = [x]

      def foo():
        MyClass().my_list.append(1)
    |}
    [
      (* TODO (T142189949): we should not be detecting leaks on instantiating a class *)
      "Global leak [3100]: Data is leaked to global `test.MyClass` of type \
       `typing.Type[test.MyClass]`.";
    ];
  assert_global_leak_errors
    {|
      import collections
      class MyClass:
        my_list: List[int] = []

      def foo():
        MyClass.my_list.append(1)
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.MyClass` of type \
       `typing.Type[test.MyClass]`.";
    ];
  assert_global_leak_errors
    {|
      import collections
      class MyClass:
        my_list: List[int]
        def __init__(self, x: int) -> None:
          self.my_list = [x]

      def foo():
        collections.my_list.append(1)
    |}
    [ (* TODO (T142189949): this functionality works correctly, but tests need to be updated to
         recognize external imports *) ];
  assert_global_leak_errors
    {|
      import collections

      def foo():
        collections.append(1)
    |}
    [ (* TODO (T142189949): this functionality works correctly, but tests need to be updated to
         recognize external imports *) ];
  assert_global_leak_errors
    {|
      class MyClass:
        x: int
        def __init__(self, x: int) -> None:
          self.x = x

      def foo():
        MyClass.x = 2
    |}
    [ (* TODO (T142189949): leaks should be detected on class attribute mutations *) ];
  assert_global_leak_errors
    {|
      class MyClass:
        x: int
        def __init__(self, x: int) -> None:
          object.__setattr__(self, "x", x)

      myclass = MyClass(1)
    |}
    [ (* TODO (T142189949): leaks should be detected on class attribute mutations *) ];
  assert_global_leak_errors
    {|
      class MyClass(dict):
        def __init__(self, x: int) -> None:
          super().__setitem__("x", 1)

      myclass = MyClass(1)
    |}
    [];
  ()


let test_global_statements context =
  let assert_global_leak_errors = assert_global_leak_errors ~context in
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        return my_global
    |}
    [ (* TODO (T142189949): a global should not be able to be returned by a function *) ];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
         y = my_global
    |}
    [ (* TODO (T142189949): leaks should be detected on global assignment to a local variable *) ];
  (* TODO (T142189949): leaks should be detected on global assignment to a local variable through
     tuple deconstruction *)
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
         x, y = my_global, 1
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        my_list = []
        my_list.append(my_global)
    |}
    [ (* TODO (T142189949): leaks should be detected for writing a global into a local *) ];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        my_dict = {}
        my_dict["my_global"] = my_global
    |}
    [ (* TODO (T142189949): leaks should be detected for writing a global into a local *) ];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        my_dict = {}
        my_dict[my_global] = "my_global"
    |}
    [ (* TODO (T142189949): leaks should be detected for writing a global into a local *) ];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        my_set = set()
        my_set.add(my_global)
    |}
    [ (* TODO (T142189949): leaks should be detected for writing a global into a local *) ];
  assert_global_leak_errors
    {|
      class MyClass:
        x: int
        def __init__(self, x: int) -> None:
          self.x = x

      my_global: int = 1

      def foo():
        my_obj = MyClass()
        my_obj.x = my_global
    |}
    [ (* TODO (T142189949): leaks should be detected for writing a global into a local *) ];
  assert_global_leak_errors
    {|
      class MyClass:
        x: int
        def __init__(self, x: int) -> None:
          self.x = x

      my_global: int = 1

      def foo():
        MyClass().x = my_global
    |}
    [
      (* TODO (T142189949): leaks should be detected for writing a global into a local *)
      (* TODO (T142189949): we should not be detecting leaks on instantiating a class *)
      "Global leak [3100]: Data is leaked to global `test.MyClass` of type \
       `typing.Type[test.MyClass]`.";
    ];
  assert_global_leak_errors
    {|
      class MyClass:
        x: int
        def __init__(self, x: int) -> None:
          self.x = x

      my_global: MyClass = MyClass()

      def foo():
        my_local = my_global.x
    |}
    [ (* TODO (T142189949): should this be allowed? *) ];
  assert_global_leak_errors {|
      print(5)
    |} [];
  assert_global_leak_errors
    {|
      async def test() -> None:
        print("Hello")
        yield
    |}
    [];
  assert_global_leak_errors
    {|
      async def test() -> int:
        yield from (i for i in range(10))
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def test() -> None:
        global my_global
        ~my_global.setdefault("a", 1)
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def test() -> None:
        global my_global
        await async_func(my_global.setdefault("a", 1))
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        my_global.setdefault("a", 1) and True
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        True or my_global.setdefault("a", 1)
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        5 > my_global.setdefault("a", 1)
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        my_global.setdefault("a", 1) == 5
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        a = "hello"
        f"{a} world: {my_global.setdefault('a', 1) == 5}"
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        a = lambda: my_global.append(1)
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        a = lambda x = my_global.setdefault("a", 1): x
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        a = my_global.setdefault("a", 1) if False else 3
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        a = 1 if my_global.setdefault("a", 1) else 2
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        a = 1 if True else my_global.setdefault("a", 1)
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        if my_global == 1:
          my_global = 3
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        if my_global == 1:
          my_global = 3
        else:
          my_global = 4
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        if my_global := 3:
          my_global = 3
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        if my_global := (a := 3):
          print("hi")
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        if True:
          my_global = 2
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        if True:
          my_global = 2
        else:
          my_local = 3
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        if True:
          my_local = 2
        else:
          my_global = 3
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo():
        global my_global
        if True:
          my_local = 2
        elif my_global == 1:
          my_global = 3
        else:
          my_local = 4
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 0
      my_global_t: int = 1
      def foo():
        global my_global
        if True:
          my_local = 2
        elif my_global_t := 3:
          my_local = 3
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global_t` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 0
      def foo():
        while True:
          my_global += 1
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 0
      def foo():
        while True:
          my_local += 1
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 0
      def foo():
        global my_global
        while True:
          my_global += 1
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 0
      def foo():
        global my_global
        while my_global := 3:
          print("hi")
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 0
      def foo():
        while my_global := 3:
          print("hi")
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        for i in "hello":
          print("hi")
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        for i in range(0, my_global):
          print("hi")
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        global my_global
        for i in range(0, 10):
          my_global = 4
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo() -> None:
        for i in (my_global := [1]):
          print("hi")
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo() -> None:
        for i in range(my_global.setdefault("a", 1)):
          print("hi")
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      def foo() -> None:
        with open("hello", "r") as f:
          print("hi")
    |}
    [];
  assert_global_leak_errors
    {|
      def foo() -> None:
        with open("hello", "r") as f, open("world", "r") as f1:
          print("hi")
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        global my_global
        with open("hello", "r") as f:
          my_global = 2
          print("hi")
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        global my_global
        with open("hello", "r") as my_global:
          print("hi")
    |}
    (* TODO (T142189949): should pyre figure out the right type here? *)
    ["Global leak [3100]: Data is leaked to global `my_global` of type `unknown`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        global my_global
        with open("hello", "r") as f, open("world", "r") as f1:
          my_global = 2
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        global my_global
        with open("hello", "r") as my_global, open("world", "r") as f1:
          print("hi")
    |}
    (* TODO (T142189949): should pyre figure out the right type here? *)
    ["Global leak [3100]: Data is leaked to global `my_global` of type `unknown`."];
  assert_global_leak_errors
    {|
      from x import my_global
      def foo() -> None:
        global my_global
        my_global.append(1)
    |}
    ["Global leak [3100]: Data is leaked to global `x.my_global` of type `unknown`."];
  assert_global_leak_errors
    {|
      from collections import my_global
      def foo() -> None:
        my_global.append(1)
    |}
    [ (* TODO (T142189949): this functionality works correctly, but tests need to be updated to
         recognize external imports *) ];
  ()


let test_recursive_coverage context =
  let assert_global_leak_errors = assert_global_leak_errors ~context in
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        print(my_global.append(123))
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  assert_global_leak_errors
    {|
      my_global: List[int] = []
      def foo():
        global my_global
        a = my_global.append(123)
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  assert_global_leak_errors
    {|
      my_global: List[List[int]] = [[]]
      def foo():
        global my_global
        my_global[0].append(1)
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type \
       `typing.List[typing.List[int]]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: List[List[int]] = [[]]
      def foo():
        global my_global
        my_global.get(0)[1] = 5
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type \
       `typing.List[typing.List[int]]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def setdefault_global_dict() -> None:
        return my_global.setdefault(1, "a")
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def setdefault_global_dict() -> None:
        raise Exception(my_global.setdefault("a", 1))
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def setdefault_global_dict() -> None:
        raise Exception() from Exception(my_global.setdefault("a", 1))
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def test() -> None:
        global my_global
        yield my_global.setdefault("a", 1)
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def test() -> None:
        global my_global
        yield my_global.setdefault("a", 1)
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def test() -> None:
        global my_global
        return [
          (my_global.setdefault("a", 1), 2),
          [my_global.setdefault("a", 1), 2],
        ]
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        my_local = [1, 2, 3]
        my_local[my_global.setdefault("a", 1)] = 0
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        my_local = [1, 2, 3]
        my_local[my_global.setdefault("a", 1) < 5] = 0
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        my_local = [1, 2, 3]
        my_local[my_global.setdefault("a", 1) and True] = 0
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      my_global: Dict[str, int] = {}
      def foo():
        a = (1 if my_global.setdefault("a", 1) else 2) if True else 4
    |}
    [
      "Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.Dict[str, \
       int]`.";
    ];
  assert_global_leak_errors
    {|
      def foo() -> None:
        try:
          x = 5
        except:
          print("An exception occurred")
    |}
    [];
  assert_global_leak_errors
    {|
      def foo() -> None:
        try:
          my_local= 5
        except NameError:
          print("Variable my_local is not defined")
        except:
          print("An exception occurred")
    |}
    [];
  assert_global_leak_errors
    {|
      def foo() -> None:
        try:
          x = 5
        except:
          print("An exception occurred")
        else:
          print("No exception")
    |}
    [];
  assert_global_leak_errors
    {|
      def foo() -> None:
        try:
          x = 5
        except:
          print("An exception occurred")
        finally:
          print("try except is complete")
    |}
    [];
  assert_global_leak_errors
    {|
      def foo() -> None:
        try:
          my_local = 1
        except Exception as e:
          my_local = 2
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        global my_global
        try:
          my_local = 1
        except Exception as my_global:
          my_local = 2
    |}
    ["Global leak [3100]: Data is leaked to global `my_global` of type `unknown`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        global my_global
        try:
          my_global = 1
        except:
          print("An exception occurred")
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        try:
          global my_global
          my_global = 1
        except:
          print("An exception occurred")
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        try:
          my_local = 1
        except:
          global my_global
          my_global = 1
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        try:
          my_local = 1
        except:
          my_local = 2
        else:
          global my_global
          my_global = 1
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      my_global: int = 1
      def foo() -> None:
        try:
          my_local = 1
        except:
          my_local = 2
        finally:
          global my_global
          my_global = 1
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `int`."];
  assert_global_leak_errors
    {|
      def nested_run():
          def do_the_thing():
              my_local.append(1)

          do_the_thing()
    |}
    [];
  assert_global_leak_errors
    {|
      my_global: List[int] = []

      def nested_run():
          def do_the_thing():
              my_global.append(1)

          do_the_thing()
    |}
    ["Global leak [3100]: Data is leaked to global `test.my_global` of type `typing.List[int]`."];
  ()


let () =
  "global_leaks"
  >::: [
         "global_assignment" >:: test_global_assignment;
         "list_global_leaks" >:: test_list_global_leaks;
         "dict_global_leaks" >:: test_dict_global_leaks;
         "set_global_leaks" >:: test_set_global_leaks;
         "object_global_leaks" >:: test_object_global_leaks;
         "global_statements" >:: test_global_statements;
         "recursive_coverage" >:: test_recursive_coverage;
       ]
  |> Test.run
