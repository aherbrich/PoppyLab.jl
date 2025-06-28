############### CLEANING FUNCTIONS ################

function clean_move_string(move_string::AbstractString)::String
    move_string = replace(move_string, r"\{[^\}]*\}" => "")                   # Remove comments
    move_string = replace(move_string, r"\d+\." => "")                        # Remove move numbers
    move_string = replace(move_string, r"1-0|0-1|1/2-1/2" => "")              # Remove results
    move_string = replace(move_string, r"[.#?!*+]" => "")                     # Remove annotations
    return join(split(move_string), " ")                                      # Normalize whitespace
end


############### PGN PARSING ################

function extract_move_strings_from_pgn_file(input_file_path::String; min_elo::Int=0)::Vector{String}
    move_strings = String[]
    metadata = Dict{String, String}()

    open(input_file_path, "r") do io
        for line in eachline(io)
            line = strip(line)
            isempty(line) && continue

            if startswith(line, "[") && endswith(line, "]")
                if (m = match(r"\[(\w+)\s+\"([^\"]+)\"\]", line)) !== nothing
                    metadata[m.captures[1]] = m.captures[2]
                end
            elseif startswith(line, "1.")
                if has_required_elo(metadata, min_elo)
                    push!(move_strings, clean_move_string(line))
                end
                metadata = Dict{String, String}()  # Reset for next game
            end
        end
    end

    return move_strings
end

function has_required_elo(metadata::Dict{String, String}, min_elo::Int)::Bool
    haskey(metadata, "WhiteElo") && haskey(metadata, "BlackElo") || return false

    white_elo = tryparse(Int, metadata["WhiteElo"])
    black_elo = tryparse(Int, metadata["BlackElo"])

    if isnothing(white_elo) || isnothing(black_elo)
        @warn "Invalid or missing Elo in metadata: $metadata"
        return false
    end

    return white_elo >= min_elo && black_elo >= min_elo
end


############### VALIDATION ################

function is_valid_move_string(move_string::AbstractString)::Bool
    board = PoppyCore.Board()
    PoppyCore.set_by_fen!(board, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")

    for move_str in split(move_string)
        try
            move = PoppyCore.extract_move_by_san(board, move_str)
            PoppyCore.do_move!(board, move)
        catch
            return false
        end
    end
    return true
end


############### MOVE TO SAN ################

function index_to_square(index)
    file = Char('a' + PoppyCore.file(index))
    rank = Char('1' + PoppyCore.rank(index))
    return string(file, rank)
end

function move_to_san(board::PoppyCore.Board, move)::String
    src_file = PoppyCore.file(move.src)
    src_rank = PoppyCore.rank(move.src)
    dst_sq = index_to_square(move.dst)

    piece = board.squares[move.src + 1] & 0x07
    is_promotion = (move.type & PoppyCore.PROMOTION) != 0
    is_capture = (move.type & PoppyCore.CAPTURE) != 0

    # Castling
    if move.type == PoppyCore.KING_CASTLE
        return "O-O"
    elseif move.type == PoppyCore.QUEEN_CASTLE
        return "O-O-O"
    end

    # Promotion
    if is_promotion
        promo_type = move.type & 0x03
        promo_letter = promo_type == (PoppyCore.KNIGHT_PROMOTION & 0x03) ? "N" :
                       promo_type == (PoppyCore.BISHOP_PROMOTION & 0x03) ? "B" :
                       promo_type == (PoppyCore.ROOK_PROMOTION & 0x03)   ? "R" :
                       promo_type == (PoppyCore.QUEEN_PROMOTION & 0x03)  ? "Q" :
                       error("Unknown promotion type")

        return is_capture ?
            string(Char(src_file + 'a'), "x", dst_sq, "=", promo_letter) :
            string(Char(src_file + 'a'), dst_sq, "=", promo_letter)
    end

    # Normal moves
    piece_letter = piece == KNIGHT ? "N" :
                   piece == BISHOP ? "B" :
                   piece == ROOK   ? "R" :
                   piece == QUEEN  ? "Q" :
                   piece == KING   ? "K" : ""

    # Disambiguation
    _, legal_moves = PoppyCore.generate_legals(board)
    similar_moves = filter(m -> m.dst == move.dst &&
                               m.src != move.src &&
                               (board.squares[m.src + 1] & 0x07) == piece, legal_moves)

    disambiguation = ""
    if !isempty(similar_moves) && piece != PAWN
        same_file = any(m -> PoppyCore.file(m.src) == src_file, similar_moves)
        same_rank = any(m -> PoppyCore.rank(m.src) == src_rank, similar_moves)

        disambiguation = if !same_file
            string(Char(src_file + 'a'))
        elseif !same_rank
            string(src_rank + 1)
        else
            string(Char(src_file + 'a'), src_rank + 1)
        end
    end

    if piece == PAWN
        return is_capture ?
            string(Char(src_file + 'a'), "x", dst_sq) :
            dst_sq
    else
        return string(piece_letter, disambiguation, is_capture ? "x" : "", dst_sq)
    end
end


############### MAIN PIPELINE ################

function preprocess_pgn_file(input_file_path::String, output_file_path::String)
    min_elo = 2500
    move_strings = extract_move_strings_from_pgn_file(input_file_path, min_elo=min_elo)

    println("Extracted $(length(move_strings)) move strings with Elo ≥ $min_elo")

    println("Validating move strings...")
    for move_string in move_strings
        is_valid_move_string(move_string) || @warn "Invalid move string: $move_string"
    end

    println("Writing output to $output_file_path...")
    open(output_file_path, "w") do output
        for move_string in move_strings
            board = PoppyCore.Board()
            PoppyCore.set_by_fen!(board, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")

            for move_str in split(move_string)
                _, legal_moves = PoppyCore.generate_legals(board)
                move = PoppyCore.extract_move_by_san(board, move_str)

                best_idx = findfirst(m -> m.src == move.src && m.dst == move.dst && m.type == move.type, legal_moves)
                isnothing(best_idx) && error("Expected move not found in legals")

                # Put the correct move first
                legal_moves[1], legal_moves[best_idx] = legal_moves[best_idx], legal_moves[1]

                san_moves = map(m -> move_to_san(board, m), legal_moves)
                
                # check if move_to_san returns valid SAN strings
                for san_move in san_moves
                    try
                        PoppyCore.extract_move_by_san(board, san_move)
                    catch e
                        @warn "Something went wrong in move_to_san: $san_move"
                        @warn "Error: $e"
                    end
                end

                board_fen = PoppyCore.extract_fen(board)

                # check if board_fen is correct
                try
                    board2 = PoppyCore.Board()
                    PoppyCore.set_by_fen!(board2, board_fen)
                    if PoppyCore.calculate_hash(board) != PoppyCore.calculate_hash(board2)
                        @warn "Hash mismatch for board FEN: $board_fen"
                    end
                catch e
                    @warn "Something went wrong in extract_fen: $board_fen"
                    @warn "Error: $e"
                end

                output_line = "<$board_fen> <$(join(san_moves, " "))>"

                println(output, output_line)
                PoppyCore.do_move!(board, move)
            end
        end
    end
    println("Done writing to $output_file_path")
end
