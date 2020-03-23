# This file is a part of ValueShapes.jl, licensed under the MIT License (MIT).

using ValueShapes
using Test

@testset "valueaccessor" begin
    acc = @inferred ValueAccessor(ArrayShape{Real}(2,3), 2)
    @test @inferred(valshape(acc)) == ArrayShape{Real,2}((2, 3))
    data = [1, 2, 3, 4, 5, 6, 7, 8, 9]
    @test @inferred(data[acc]) == [3 5 7; 4 6 8]

    @test_throws ArgumentError Broadcast.broadcastable(acc)

    @test @inferred(size(acc)) == getproperty(getproperty(acc, :shape), :dims)

    @test @inferred(length(acc)) == length(getproperty(acc, :shape))

    @test @inferred(ValueShapes.default_unshaped_eltype(acc)) == @inferred(ValueShapes.default_unshaped_eltype(getproperty(acc, :shape)))

end
