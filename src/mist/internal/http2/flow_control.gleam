import gleam/int

pub fn compute_receive_window(
  receive_window_size: Int,
  data_size: Int,
) -> #(Int, Int) {
  let new_receive_window_size = receive_window_size - data_size

  let max_window_increment = int.bitwise_shift_left(1, 31) - 1
  let max_window_size = max_window_increment
  let min_window_size = int.bitwise_shift_left(1, 30)

  case new_receive_window_size > min_window_size {
    True -> {
      #(new_receive_window_size, 0)
    }
    False -> {
      let updated_receive_window_size =
        int.min(new_receive_window_size + max_window_increment, max_window_size)
      let increment = updated_receive_window_size - new_receive_window_size

      #(updated_receive_window_size, increment)
    }
  }
}

pub fn update_send_window(
  current_send_window: Int,
  increment: Int,
) -> Result(Int, String) {
  let max_window_size = int.bitwise_shift_left(1, 31) - 1
  let update = current_send_window + increment
  case update > max_window_size {
    True -> Error("Invalid update increment")
    False -> Ok(update)
  }
}
