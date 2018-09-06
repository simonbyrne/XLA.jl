
struct XlaType
    which::Int32
end

const xla_type_mapping = Dict{Int32, Type}(
    xla.PrimitiveType.PRED => Bool,
    xla.PrimitiveType.S8   => Int8,
    xla.PrimitiveType.S16  => Int16,
    xla.PrimitiveType.S32  => Int32,
    xla.PrimitiveType.S64  => Int64,
    xla.PrimitiveType.U8   => UInt8,
    xla.PrimitiveType.U16  => UInt16,
    xla.PrimitiveType.U32  => UInt32,
    xla.PrimitiveType.U64  => UInt64,
    xla.PrimitiveType.F16  => Float16,
    xla.PrimitiveType.F32  => Float32,
    xla.PrimitiveType.F64  => Float64,
    xla.PrimitiveType.C64  => Complex{Float32},
)
const reverse_xla_type_mapping = Dict(v=>k for (k,v) in xla_type_mapping)


function Base.convert(::Type{Type}, t::XlaType)
    xla_type_mapping[t.which]
end

function Base.convert(::Type{XlaType}, t::Type)
    XlaType(reverse_xla_type_mapping[t])
end

function buffer_to_shape(s::Shape, b::Vector)
    if s.layout.minor_to_major != 0:(length(s.dimensions)-1)
      r = reshape(b, tuple(s.dimensions[s.layout.minor_to_major .+ 1]...))
      perm = tuple((x+1 for x in s.layout.minor_to_major)...)
      @Base.show typeof(r)
      return PermutedDimsArray(r, perm)
    else
      return reshape(b, tuple(s.dimensions...))
    end
end

# ComputationDataHandle
# Ideally we'd use the one generated by ProtoBufs, but this is more convenient
# for now.
struct CDH
    handle::Int64
end
function Cxx.cppconvert(c::CDH)
    icxx"""
        xla::ComputationDataHandle CDH;
        CDH.set_handle($(c.handle));
        return CDH;
    """
end

function xla_shapeof(x::Array)
    xlat = convert(XlaType, eltype(x))
    l = Layout(format=1,
               minor_to_major=collect(0:(ndims(x)-1)))
    Shape(element_type=xlat.which, dimensions=Int64[size(x)...],
          layout=l)
end

function check_error(builder)
    icxx"""
        auto first_error = $builder->first_error();
        if (!first_error.ok()) {
            auto err = first_error.error_message();
            $:(error(String(icxx"return err;")));
        }
        return;
    """
end

macro check_error(arg)
    quote
        res = $(esc(arg))
        check_error($(esc(:builder)))
        res
    end
end

function Parameter(builder, idx, shape, name)
    name = String(name)
    @check_error CDH(icxx"""
        std::string arg_name($(pointer(name)), $(sizeof(name)));
        $builder->Parameter($idx, $shape, arg_name).handle();
    """)
end

function Add(builder, a, b)
    @check_error CDH(icxx"""
        $builder->Add($a, $b).handle();
    """)
end

function Mul(builder, a, b)
    @check_error CDH(icxx"""
        $builder->Mul($a, $b).handle();
    """)
end

function Max(builder, a, b)
    @check_error CDH(icxx"""
        $builder->Max($a, $b).handle();
    """)
end

function Dot(builder, a, b)
    @check_error CDH(icxx"""
        $builder->Dot($a, $b).handle();
    """)
end

function Map(builder, operands, sub_builder)
    ops = icxx"std::vector<xla::ComputationDataHandle>{};"
    for op in operands
        icxx"$ops.push_back($op);"
    end
    @check_error CDH(icxx"""
        std::vector<long long> dims;
        auto op0shape_res = $builder->GetShape($ops[0]);
        if (!op0shape_res.ok()) {
            auto err = op0shape_res.status().error_message();
            $:(error(String(icxx"return err;")));
        }
        auto op0shape = std::move(op0shape_res.ValueOrDie());
        for (int i = 0; i < op0shape->dimensions_size(); ++i)
            dims.push_back(i);
        return $builder->Map($ops, $sub_builder->Build().ValueOrDie(), dims).handle();
    """)
end

function GetShape(builder, arg)
    local shape
    icxx"""
        auto res = $builder->GetShape($arg);
        if (!res.ok()) {
            auto err = res.status().error_message();
            $:(error(String(icxx"return err;")));
        }
        auto res_shape = std::move(res.ValueOrDie());
        std::string data;
        res_shape->SerializeToString(&data);
        $:(begin
          shape = readproto(IOBuffer(String(icxx"return data;")), Shape())
          nothing
        end);
        return;
    """
    shape
end

function ConstantLiteral(builder, lit)
    @check_error CDH(icxx"""
        return $builder->ConstantLiteral(*$lit).handle();
    """)
end

function ConvertElementType(builder, x, T::XlaType)
    @check_error CDH(icxx"""
        return $builder->ConvertElementType($x, (xla::PrimitiveType)$(T.which)).handle();
    """)
end

function Reshape(builder, arg, collapse_dims, new_sizes)
    @check_error CDH(icxx"""
        xla::int64 *cdims_ptr = (xla::int64 *)$(pointer(collapse_dims));
        xla::int64 *nsizes_ptr = (xla::int64 *)$(pointer(new_sizes));
        auto cdims = std::vector<long long>{cdims_ptr, cdims_ptr + $(length(collapse_dims))};
        auto nsizes = std::vector<long long>{nsizes_ptr, nsizes_ptr + $(length(new_sizes))};
        return $builder->Reshape($arg, cdims, nsizes).handle();
    """)
end

function CreateSubBuilder(builder, name)
    @check_error icxx"""
        std::string name($(pointer(name)), $(sizeof(name)));
        $builder->CreateSubBuilder(name).release();
    """
end

function Build(builder)
    @check_error icxx"""
        auto res = $builder->Build();
        if (!res.ok()) {
            auto err = res.status().error_message();
            $:(error(String(icxx"return err;")));
        }
        res.ValueOrDie();
    """
end

function codegen_broadcast(builder, elT, arghandles)
    # First codegen the computation
    sub_builder = CreateSubBuilder(builder, "broadcast_f")
    sub_parameters = map(enumerate(arghandles)) do (i, _)
        Parameter(sub_builder, i-1, Shape(
            element_type = convert(XlaType, elT).which,
        ), "x_$i")
    end
    Add(sub_builder, sub_parameters...)
    Map(builder, arghandles, Build(sub_builder))
end

struct CodeGenState
    args::Vector{CDH}
    ssavals::Vector{CDH}
end

function abstract_eval_xla(builder, state, expr)
    if isa(expr, SSAValue)
        return state.ssavals[expr.id]
    elseif isa(expr, Compiler.Argument)
        return state.args[expr.n]
    elseif isa(expr, Array)
        return ConstantLiteral(builder, convert(pcpp"xla::Literal", expr))
    elseif isa(expr, Union{Float32, Float64})
        return ConstantLiteral(builder, convert(pcpp"xla::Literal", fill(expr)))
    else
        error("$expr unsupported for evaluation")
    end
end

function generate_xla_from(builder, ir, world, argnames, argshapes)
    state = CodeGenState(CDH[CDH(0)], fill(CDH(0), length(ir.stmts)))
    for (i, typ) in enumerate(ir.argtypes)
        i == 1 && continue
        push!(state.args, Parameter(builder, i-2, argshapes[i-1], argnames[i]))
    end
    local retval
    for i = 1:length(ir.stmts)
        expr = ir[SSAValue(i)]
        if isexpr(expr, :call)
            if Compiler.is_known_call(expr, Base.broadcast, ir, ir.mod)
                broadcastee = expr.args[2]
                arghandles = map(e->abstract_eval_xla(builder, state, e), expr.args[3:end])
                nargs = length(expr.args)-2
                if isa(broadcastee, Compiler.IRCode)
                    broadcastee_ir = broadcastee
                else
                    bt = Compiler.exprtype_func(broadcastee, ir)
                    if bt === Nothing
                        error("Unable to infer broadcast argument")
                    end
                    (f, ft) = bt
                    atype = Tuple{Compiler.widenconst(ft), (Float32 for i = 1:nargs)...}
                    min_valid = UInt[typemin(UInt)]
                    max_valid = UInt[typemax(UInt)]
                    meth = Base._methods_by_ftype(atype, 1, world, min_valid, max_valid)
                    if meth === false || length(meth) != 1
                        error("Broadcastee method match failed")
                    end
                    broadcastee_ir = method_match_to_ir(meth, Tuple{atype.parameters[2:end]...})[1]
                end
                sub_builder = CreateSubBuilder(builder, "broadcast_f")
                broadcastee_xla = generate_xla_from(sub_builder,
                  broadcastee_ir, world, ["x_$i" for i = 1:(nargs+1)],
                  [Shape(element_type=convert(XlaType, Float32).which) for _=1:nargs])
                state.ssavals[i] = Map(builder, arghandles, sub_builder)
            elseif Compiler.is_known_call(expr, +, ir, ir.mod) || Compiler.is_known_call(expr, Base.add_float, ir, ir.mod)
                arghandles = map(e->abstract_eval_xla(builder, state, e), expr.args[2:end])
                @assert length(arghandles) == 2
                state.ssavals[i] = Add(builder, arghandles...)
            elseif Compiler.is_known_call(expr, *, ir, ir.mod)
                argtypes = [Compiler.widenconst(Compiler.exprtype(arg, ir, ir.mod)) for arg in expr.args]
                arghandles = map(e->abstract_eval_xla(builder, state, e), expr.args[2:end])
                if all(t->t<:Array, argtypes[2:end])
                    # Compute what type base would have given this
                    TS = Base.promote_op(LinearAlgebra.matprod, eltype(argtypes[2]), eltype(argtypes[3]))
                    shapes = [GetShape(builder, handle).dimensions for handle in arghandles]
                    arghandles = map(zip(argtypes[2:end], arghandles)) do (typ,handle)
                        if eltype(typ) != TS
                            handle = ConvertElementType(builder, handle, convert(XlaType, TS))
                        end
                        if ndims(typ) == 1
                            hshape = GetShape(builder, handle)
                            handle = Reshape(builder, handle, [0],
                              push!(copy(hshape.dimensions), 1))
                        end
                        handle
                    end
                    result_shape = ndims(argtypes[3]) == 1 ? Int[shapes[1][1]] : Int[shapes[1][1], shapes[1][end]]
                    # Matmul
                    state.ssavals[i] = Reshape(builder,
                      Dot(builder, arghandles...), [0, 1], result_shape
                      )
                else
                    # Scalar Multiplication
                    state.ssavals[i] = Mul(builder, arghandles...)
                end
            elseif Compiler.is_known_call(expr, max, ir, ir.mod)
                arghandles = map(e->abstract_eval_xla(builder, state, e), expr.args[2:end])
                argtypes = [Compiler.widenconst(Compiler.exprtype(arg, ir, ir.mod)) for arg in expr.args]
                op_type = promote_type(argtypes[2:end]...)
                arghandles = map(zip(arghandles, argtypes[2:end])) do (arg, typ)
                    if typ != op_type
                        arg = ConvertElementType(builder, arg, convert(XlaType, op_type))
                    end
                    arg
                end
                state.ssavals[i] = Max(builder, arghandles...)
            else
                error("Unkown call $expr")
            end
        elseif isa(expr, Array)
            state.ssavals[i] = abstract_eval_xla(builder, state, expr)
        elseif isa(expr, Compiler.ReturnNode)
            retval = abstract_eval_xla(builder, state, expr.val)
        end
    end
    return retval
end

function method_match_to_ir(methds, types)
    if length(methds) != 1
        @show methds
        @assert false
    end
    x = methds[1]
    meth = Core.Main.Base.func_for_method_checked(x[3], types)
    world = ccall(:jl_get_world_counter, UInt, ())
    params = Compiler.Params(world)
    (_, ci, ty) = Compiler.typeinf_code(meth, x[1], x[2], false, false, params)
    ci === nothing && error("inference not successful") # Inference disabled?
    topline = Compiler.LineInfoNode(Main, Compiler.NullLineInfo.method, Compiler.NullLineInfo.file, 0, 0)
    linetable = [topline]
    Compiler.just_construct_ssa(ci, copy(ci.code), length(types.parameters), linetable), linetable

end

function generate_xla_for(builder, func, argtypes, argshapes, args)
    ir, linetable = grab_ir_for(func, argtypes)
    ir = Compiler.compact!(ir)
    # Perform partial evaluation with respect to the closure we're invoking
    # (This is a huge hack).
    ir = partial_evaluation_inlining_pass!(ir, linetable, Dict(1=>args[1]))
    ir = Compiler.compact!(ir)
    world = ccall(:jl_get_world_counter, UInt, ())
    return generate_xla_from(builder, ir, world, ["arg$i" for i = 1:(length(argtypes.parameters)+2)], argshapes)
end

function grab_ir_for(func, argtypes)
    types = Core.Main.Base.to_tuple_type(argtypes)
    world = ccall(:jl_get_world_counter, UInt, ())
    methds = Core.Main.Base._methods(func, types, -1, world)
    ir, linetable = method_match_to_ir(methds, types)
    return ir, linetable
end

function shapesof(args...)
    collect(xla_shapeof(x) for x in args)
end

function Base.convert(::Type{pcpp"xla::Literal"}, a::Array)
    T = eltype(a)
    shape = xla_shapeof(a)
    literal = icxx"new xla::Literal($shape);"
    byte_ptr = Ptr{T}(icxx"$literal->untyped_data();")
    @GC.preserve a Base.unsafe_copyto!(byte_ptr, pointer(a), length(a))
    literal
end

function Base.convert(::Type{<:vcpp"xla::Shape"}, shape::Shape)
  ser_shape = IOBuffer()
  writeproto(ser_shape, shape)
  data = take!(ser_shape)
  icxx"""
      std::string shape_data($(pointer(data)), $(sizeof(data)));
      xla::Shape shape;
      shape.ParseFromString(shape_data);
      return shape;
  """
end
Cxx.cppconvert(x::Shape) = convert(vcpp"xla::Shape", x)

using InteractiveUtils: typesof
function gen_call_with_extracted_types_and_shapes(__module__, fcn, tfcn, ex0)
    if isa(ex0, Expr)
        if any(a->(Meta.isexpr(a, :kw) || Meta.isexpr(a, :parameters)), ex0.args)
            error("Unsupported")
        elseif ex0.head == :call
            allargs = map(esc, ex0.args)
            args = allargs[2:end]
            return Expr(:tuple,
                Expr(:call, fcn, :builder, esc(ex0.args[1]),
                    Expr(:call, typesof, args...),
                    Expr(:call, shapesof, args...),
                    Expr(:tuple, allargs...)),
                Expr(:call, tfcn, args...))
        end
    end
    error("Unsupported")
end

function gen_call_with_extracted_types(__module__, fcn, tfcn, ex0)
    if isa(ex0, Expr)
        if any(a->(Meta.isexpr(a, :kw) || Meta.isexpr(a, :parameters)), ex0.args)
            error("Unsupported")
        elseif ex0.head == :call
            args = map(esc, ex0.args[2:end])
            return Expr(:call, fcn, esc(ex0.args[1]),
                    Expr(:call, typesof, args...))
        end
    end
    error("Unsupported")
end

function TransferToServer(lit)
    icxx"""
        auto handle = $client->TransferToServer(*$lit);
        if (!handle.ok()) {
            auto err = handle.status().error_message();
            $:(error(String(icxx"return err;")));
        }
        handle.ValueOrDie().release();
    """
end

function TransferArgs(args...)
    vec = icxx"std::vector<xla::GlobalData*>{};"
    for arg in args
        val = TransferToServer(convert(pcpp"xla::Literal", arg))
        icxx"$vec.push_back($val);"
    end
    vec
end

macro grab_ir(expr)
    call = gen_call_with_extracted_types(__module__, Expr(:quote, grab_ir_for), Expr(:quote, TransferArgs), expr)
    quote
        $call
    end
end

function RunXLA(client, builder, comp, args)
    local shape
    local val
    String(icxx"""
        bool ok = $builder->SetReturnValue($comp).ok();
        if (!ok) {
            auto err = $builder->first_error().error_message();
            $:(error(String(icxx"return err;")));
        }
        std::string data;
        auto res = $client->ExecuteAndTransfer($builder->Build().ValueOrDie(),
            $args);
        if (!res.ok()) {
            auto err = res.status().error_message();
            $:(error(String(icxx"return err;")));
        }
        auto res_val = std::move(res.ValueOrDie());
        res_val->shape().SerializeToString(&data);
        void *bytes = res_val->untyped_data();
        $:(begin
          shape = readproto(IOBuffer(String(icxx"return data;")), Shape())
          eltyp = convert(Type, XlaType(shape.element_type))
          val = buffer_to_shape(shape, copy(unsafe_wrap(Array, Ptr{eltyp}(icxx"return bytes;"), (prod(shape.dimensions),))))
          nothing
        end);
        return data;
    """)
    val
end

macro xla(expr)
    call = gen_call_with_extracted_types_and_shapes(__module__, Expr(:quote, generate_xla_for), Expr(:quote, TransferArgs), expr)
    quote
        builder = icxx"""new xla::ComputationBuilder($client, "test");"""
        (comp, args) = $call
        RunXLA(client, builder, comp, args)
    end
end

include("partial_inline.jl")
