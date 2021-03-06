!--------------------------------------------------------------------
!> Downscaling
!
!> @author Johannes Gebert - HLRS - NUM - gebert@hlrs.de
!> Date:    15.01.2022
!> LastMod: 07.05.2022
!--------------------------------------------------------------------
PROGRAM downscaling

USE ISO_FORTRAN_ENV
USE global_std
USE user_interaction
USE meta
USE MPI
USE raw_binary
USE formatted_plain
USE image_manipulation

IMPLICIT NONE

INTEGER(ik), PARAMETER :: debug = 2   ! Choose an even integer

CHARACTER(mcl), DIMENSION(:), ALLOCATABLE :: m_rry
CHARACTER(scl) :: type, binary, restart, restart_cmd_arg, datarep=''
CHARACTER(mcl) :: cmd_arg_history='', stat='' 
CHARACTER(  8) :: date
CHARACTER( 10) :: time

INTEGER(INT16), DIMENSION(:,:,:), ALLOCATABLE :: rry_ik2, rry_out_ik2
INTEGER(INT32), DIMENSION(:,:,:), ALLOCATABLE :: rry_ik4, rry_out_ik4
INTEGER(mik) :: sections(3), ierr, my_rank, size_mpi

INTEGER(ik), DIMENSION(3) :: dims, rry_dims, sections_ik=0, rank_section, &
    scale_factor_ik, new_subarray_origin, remainder, new_lcl_rry_in_dims, &
    new_glbl_rry_dims, lcl_subarray_in_origin, new_lcl_rry_out_dims, &
    lcl_subarray_out_origin
INTEGER(ik) :: ii=0   

REAL(rk) :: start, end
REAL(rk), DIMENSION(3) :: origin_glbl_shft, spcng, field_of_view, new_spacing, &
    offset, scale_factor

LOGICAL :: abrt = .FALSE.


!------------------------------------------------------------------------------
! Invoke MPI 
!------------------------------------------------------------------------------
CALL mpi_init(ierr)
CALL print_err_stop(std_out, "MPI_INIT didn't succeed", INT(ierr, ik))

CALL MPI_COMM_RANK(MPI_COMM_WORLD, my_rank, ierr)
CALL print_err_stop(std_out, "MPI_COMM_RANK couldn't be retrieved", INT(ierr, ik))

CALL MPI_COMM_SIZE(MPI_COMM_WORLD, size_mpi, ierr)
CALL print_err_stop(std_out, "MPI_COMM_SIZE couldn't be retrieved", INT(ierr, ik))

IF (size_mpi < 2) CALL print_err_stop(std_out, "At least two ranks required to execute this program.", 1)

!------------------------------------------------------------------------------
! Rank 0 -- Init (Master) Process and broadcast init parameters 
!------------------------------------------------------------------------------
IF (my_rank==0) THEN

    CALL CPU_TIME(start)

    !------------------------------------------------------------------------------
    ! Parse the command arguments
    !------------------------------------------------------------------------------
    CALL get_cmd_args(binary, in%full, restart_cmd_arg, cmd_arg_history, stat)
    IF(stat/='') GOTO 1001
    
    IF (in%full=='') THEN
        CALL usage(binary)    

        !------------------------------------------------------------------------------
        ! On std_out since file of std_out is not spawned
        !------------------------------------------------------------------------------
        CALL print_err_stop(6, "No input file given", 1)
    END IF

    !------------------------------------------------------------------------------
    ! Check and open the input file; Modify the Meta-Filename / Basename
    ! Define the new application name first
    !------------------------------------------------------------------------------
    global_meta_prgrm_mstr_app = 'dos' 
    global_meta_program_keyword = 'DOWNSCALING'
    
    CALL meta_append(m_rry, size_mpi, stat); CALL std_err_handling(stat, abrt)

    !------------------------------------------------------------------------------
    ! Redirect std_out into a file in case std_out is not useful by environment.
    ! Place these lines before handle_lock_file :-)
    !------------------------------------------------------------------------------
    std_out = determine_stout()

    !------------------------------------------------------------------------------
    ! Spawn standard out after(!) the basename is known
    !------------------------------------------------------------------------------
    IF(std_out/=6) CALL meta_start_ascii(std_out, '.std_out')

    CALL show_title(["Johannes Gebert, M.Sc. (HLRS, NUM)"])
 
    IF(debug >=0) WRITE(std_out, FMT_MSG) "Post mortem info probably in ./datasets/temporary.std_out"

    !------------------------------------------------------------------------------
    ! Parse input
    !------------------------------------------------------------------------------
    WRITE(std_out, FMT_TXT) 'Reading data from *.meta file.'

    CALL meta_read('ORIGIN_SHIFT_GLBL', m_rry, origin_glbl_shft, stat); CALL std_err_handling(stat, abrt)
    
    CALL meta_read('TYPE_RAW',   m_rry, type , stat); CALL std_err_handling(stat, abrt)
    CALL meta_read('SPACING'   , m_rry, spcng, stat); CALL std_err_handling(stat, abrt)
    CALL meta_read('DIMENSIONS', m_rry, dims , stat); CALL std_err_handling(stat, abrt)
    CALL meta_read('RESTART',    m_rry, restart, stat); CALL std_err_handling(stat, abrt)

    CALL meta_read('DATA_BYTE_ORDER', m_rry, datarep, stat); CALL std_err_handling(stat, abrt)
    CALL meta_read('SCALE_FACTOR', m_rry, scale_factor_ik, stat); CALL std_err_handling(stat, abrt)
    
    IF((type /= "ik2") .AND. (type /= "ik4")) THEN
        mssg = "Program only supports ik2 and ik4 for 'TYPE_RAW'"
        CALL print_err_stop(std_out, mssg, 1)
    END IF

    !------------------------------------------------------------------------------
    ! Restart handling
    ! Done after meta_io to decide based on keywords
    !------------------------------------------------------------------------------
    CALL meta_handle_lock_file(restart, restart_cmd_arg)

END IF ! my_rank==0

!------------------------------------------------------------------------------
! Send required variables
!------------------------------------------------------------------------------
CALL MPI_BCAST(in%p_n_bsnm , INT(meta_mcl, mik), MPI_CHAR, 0_mik, MPI_COMM_WORLD, ierr)
CALL MPI_BCAST(out%p_n_bsnm, INT(meta_mcl, mik), MPI_CHAR, 0_mik, MPI_COMM_WORLD, ierr)
CALL MPI_BCAST(type        , INT(scl, mik), MPI_CHAR, 0_mik, MPI_COMM_WORLD, ierr)
CALL MPI_BCAST(datarep, INT(scl, mik), MPI_CHAR, 0_mik, MPI_COMM_WORLD, ierr)

CALL MPI_BCAST(scale_factor_ik, 3_mik, MPI_INTEGER8, 0_mik, MPI_COMM_WORLD, ierr)
CALL MPI_BCAST(dims           , 3_mik, MPI_INTEGER8, 0_mik, MPI_COMM_WORLD, ierr)
CALL MPI_BCAST(spcng          , 3_mik, MPI_DOUBLE_PRECISION, 0_mik, MPI_COMM_WORLD, ierr)
CALL MPI_BCAST(origin_glbl_shft, 3_mik, MPI_DOUBLE_PRECISION, 0_mik, MPI_COMM_WORLD, ierr)

!------------------------------------------------------------------------------
! Get dimensions for each domain. Every processor reveives its own domain.
! Therefore, each my_rank calculates its own address/dimensions/parameters.
!
! Allocation of subarray memory is done in the read_raw routines.
!------------------------------------------------------------------------------
! Calculation of the downscaling directly affects the mpi subarrays (!) 
!------------------------------------------------------------------------------
sections=0
CALL MPI_DIMS_CREATE (size_mpi, 3_mik, sections, ierr)

sections_ik = INT(sections, ik)

CALL get_rank_section(INT(my_rank, ik), sections_ik, rank_section)

!------------------------------------------------------------------------------
! Get new dimensions out of (field of view) / target_spcng
!------------------------------------------------------------------------------
scale_factor = REAL(scale_factor_ik, rk)

new_spacing = spcng * scale_factor

remainder = MODULO(dims, scale_factor_ik)

new_lcl_rry_in_dims = (dims - remainder) / sections_ik
new_lcl_rry_out_dims = (dims - remainder) / sections_ik / scale_factor_ik

!------------------------------------------------------------------------------
! Fit local array dimensions to scale_factor
!------------------------------------------------------------------------------
DO ii=1, 3
    DO WHILE(MODULO(new_lcl_rry_in_dims(ii), scale_factor_ik(ii)) /= 0_ik)


        new_lcl_rry_in_dims(ii) = new_lcl_rry_in_dims(ii) - 1_ik

    END DO
END DO 

!------------------------------------------------------------------------------
! MPI specific subarray dimensions with global offset of remainder
!------------------------------------------------------------------------------
new_glbl_rry_dims = new_lcl_rry_out_dims * sections_ik

field_of_view = new_glbl_rry_dims * new_spacing

lcl_subarray_in_origin = (rank_section-1_ik) * (new_lcl_rry_in_dims) + FLOOR(remainder/2._rk, ik)
lcl_subarray_out_origin = (rank_section-1_ik) * (new_lcl_rry_out_dims)

!------------------------------------------------------------------------------
! Remainder relative to input dimensions and spacings
!------------------------------------------------------------------------------
offset = FLOOR(remainder/2._rk) * spcng

origin_glbl_shft = origin_glbl_shft + offset

new_subarray_origin = (rank_section-1_ik) * (rry_dims)

!------------------------------------------------------------------------------
! The remainder is ignored, since the spatial resolution will break with a, 
! integer based scaling, which deformes the last voxel of dims.
!------------------------------------------------------------------------------

IF(my_rank == 0) THEN
    ! DEBUG INFORMATION
    IF (debug >= 0) THEN 
        CALL DATE_AND_TIME(date, time)
        
        WRITE(std_out, FMT_TXT) "Date: "//date//" [ccyymmdd]"
        WRITE(std_out, FMT_TXT) "Time: "//time//" [hhmmss.sss]"  
        WRITE(std_out, FMT_TXT) "Program invocation:"//TRIM(cmd_arg_history)          
        WRITE(std_out, FMT_TXT_SEP)
        WRITE(std_out, FMT_MSG_AxI0) "Debug Level:", debug
        WRITE(std_out, FMT_MSG) "Calculation of domain sectioning:"
        WRITE(std_out, FMT_MSG)
        WRITE(std_out, FMT_MSG_AxI0) "Scale factor: ", scale_factor_ik
        WRITE(std_out, FMT_MSG_AxI0) "sections: ", sections_ik
        WRITE(std_out, FMT_MSG_AxI0) "Input dims: ", dims
        WRITE(std_out, FMT_MSG_AxI0) "new_lcl_rry_in_dims: ", new_lcl_rry_in_dims
        WRITE(std_out, FMT_MSG_AxI0) "new_lcl_rry_out_dims: ", new_lcl_rry_out_dims
        WRITE(std_out, FMT_MSG_AxI0) "Output dims: ", new_glbl_rry_dims
        WRITE(std_out, FMT_MSG_AxI0) "lcl_subarray_in_origin: ", lcl_subarray_in_origin
        WRITE(std_out, FMT_MSG_SEP)
        FLUSH(std_out)
    END IF

END IF

!------------------------------------------------------------------------------
! Read binary part of the vtk file - basically a *.raw file
!
! Allocate memory for the downscaled array/image
!------------------------------------------------------------------------------
IF(my_rank==0) WRITE(std_out, FMT_TXT) 'Reading image.'

!------------------------------------------------------------------------------
! Read the clinical scan
! All ranks, complete image
!------------------------------------------------------------------------------
! Convert endianness
!------------------------------------------------------------------------------
IF(TRIM(datarep) == "BIG_ENDIAN") THEN
    datarep = "external32"
 ELSE
    datarep = "native"
 END IF 
 
SELECT CASE(type)
    CASE('ik2') 
        ALLOCATE(rry_out_ik2(new_lcl_rry_out_dims(1), new_lcl_rry_out_dims(2), new_lcl_rry_out_dims(3)))

        CALL mpi_read_raw(TRIM(in%p_n_bsnm)//raw_suf, 0_8, dims, &
            new_lcl_rry_in_dims, lcl_subarray_in_origin, rry_ik2, TRIM(datarep))

        IF(my_rank==0) THEN
            WRITE(std_out, FMT_MSG_AxI0) "Min input: ", MINVAL(rry_ik2)
            WRITE(std_out, FMT_MSG_AxI0) "Max input: ", MaxVAL(rry_ik2)
        END IF

    CASE('ik4') 
        ALLOCATE(rry_out_ik4(new_lcl_rry_out_dims(1), new_lcl_rry_out_dims(2), new_lcl_rry_out_dims(3)))

        CALL mpi_read_raw(TRIM(in%p_n_bsnm)//raw_suf, 0_8, dims, &
            new_lcl_rry_in_dims, lcl_subarray_in_origin, rry_ik4, TRIM(datarep))

        IF(my_rank==0) THEN
            WRITE(std_out, FMT_MSG_AxI0) "Min input: ", MINVAL(rry_ik4)
            WRITE(std_out, FMT_MSG_AxI0) "Max input: ", MaxVAL(rry_ik4)
        END IF
END SELECT

!------------------------------------------------------------------------------
! Compute downscaling
!------------------------------------------------------------------------------
IF(my_rank==0) WRITE(std_out, FMT_TXT) 'Downscaling image.'
    
SELECT CASE(type)
    CASE('ik2'); CALL downscale(rry_ik2, scale_factor_ik, rry_out_ik2)
    CASE('ik4'); CALL downscale(rry_ik4, scale_factor_ik, rry_out_ik4)
END SELECT

!------------------------------------------------------------------------------
! Write raw data
!------------------------------------------------------------------------------
IF(my_rank==0) WRITE(std_out, FMT_TXT) 'Writing binary information to *.raw file.'

SELECT CASE(type)
    CASE('ik2') 
        IF(my_rank==0) THEN
            WRITE(std_out, FMT_MSG_AxI0) "Min output: ", MINVAL(rry_out_ik2)
            WRITE(std_out, FMT_MSG_AxI0) "Max output: ", MaxVAL(rry_out_ik2)
        END IF 

        CALL mpi_write_raw(TRIM(out%p_n_bsnm)//raw_suf, 0_8, new_glbl_rry_dims, &
            new_lcl_rry_out_dims, lcl_subarray_out_origin, rry_out_ik2)
        DEALLOCATE(rry_out_ik2)

    CASE('ik4') 
        IF(my_rank==0) THEN
            WRITE(std_out, FMT_MSG_AxI0) "Min output: ", MINVAL(rry_out_ik4)
            WRITE(std_out, FMT_MSG_AxI0) "Max output: ", MaxVAL(rry_out_ik4)
        END IF
        
        CALL mpi_write_raw(TRIM(out%p_n_bsnm)//raw_suf, 0_8, new_glbl_rry_dims, &
            new_lcl_rry_out_dims, lcl_subarray_out_origin, rry_out_ik4)
        DEALLOCATE(rry_out_ik4)

END SELECT

!------------------------------------------------------------------------------
! Jump to end for a more gracefully ending of the program in specific cases :-)
!------------------------------------------------------------------------------
1001 CONTINUE

!------------------------------------------------------------------------------
! Finish program
!------------------------------------------------------------------------------
IF(my_rank == 0) THEN
    CALL meta_write('PROCESSORS'       , '(-)', INT(size_mpi, ik))
    CALL meta_write('SUBARRAY_SECTIONS', '(-)', sections_ik)
    
    CALL meta_write('DIMENSIONS'   , '(-)', new_glbl_rry_dims)
    CALL meta_write('SPACING'      , '(-)', new_spacing)
    CALL meta_write('FIELD_OF_VIEW', '(-)', field_of_view)
    CALL meta_write('ENTRIES'      , '(-)', PRODUCT(new_glbl_rry_dims))
    CALL meta_write('ORIGIN_SHIFT_GLBL', '(mm)', origin_glbl_shft)

    CALL CPU_TIME(end)

    WRITE(std_out, FMT_TXT_xAF0) 'Finishing the program took', end-start,'seconds.'
    WRITE(std_out, FMT_TXT_SEP)

    CALL meta_signing(binary)
    CALL meta_close()

    IF (std_out/=6) CALL meta_stop_ascii(fh=std_out, suf='.std_out')

END IF ! (my_rank == 0)

Call MPI_FINALIZE(ierr)
CALL print_err_stop(std_out, "MPI_FINALIZE didn't succeed", INT(ierr, ik))

END PROGRAM downscaling
